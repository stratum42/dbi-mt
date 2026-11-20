#!perl -w
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

BEGIN {
    unless (eval { require MT; 1 }) {
        plan skip_all => 'perl5-mt (MT) is not available';
    }
    unless (eval { require DBI; 1 }) {
        plan skip_all => 'DBI is not available';
    }
    unless (eval { require DBD::SQLite; 1 }) {
        plan skip_all => 'DBD::SQLite is not in @INC';
    }
    unless (eval { require DBI::MT::Pool; 1 }) {
        plan skip_all => 'DBI::MT::Pool is not available';
    }
}

# 1. Verify Tier 1 PERL_XS_THREADSAFE=1 flags on DBD::SQLite XSUBs
ok(
    MT::XS::is_threadsafe(\&DBD::SQLite::db::_login),
    'DBD::SQLite::db::_login is Tier 1 threadsafe'
);
ok(
    !MT::XS::is_remote(\&DBD::SQLite::db::_login),
    'DBD::SQLite::db::_login is not remote'
);
ok(
    MT::XS::is_threadsafe(\&DBD::SQLite::st::_prepare),
    'DBD::SQLite::st::_prepare is Tier 1 threadsafe'
);
ok(
    MT::XS::is_threadsafe(\&DBD::SQLite::db::sqlite_busy_timeout),
    'DBD::SQLite::db::sqlite_busy_timeout is Tier 1 threadsafe'
);

# Verify SQLite was compiled with THREADSAFE != 0
my %opts = map { $_ => 1 } DBD::SQLite::compile_options();
ok(
    $opts{'THREADSAFE=1'} || $opts{'THREADSAFE=2'},
    'bundled SQLite compiled with THREADSAFE=1 or 2'
);

# 2. Set up a WAL-mode SQLite database before MT::Image::freeze()
my $tmpdir = tempdir(CLEANUP => 1);
my $dbfile = File::Spec->catfile($tmpdir, 'mt_sqlite_test.db');
our $DSN   = "dbi:SQLite:dbname=$dbfile";

{
    my $dbh = DBI->connect($DSN, '', '', {
        RaiseError          => 1,
        PrintError          => 0,
        AutoCommit          => 1,
        sqlite_busy_timeout => 10_000,
    });
    ok($dbh, 'pre-freeze DBI->connect to SQLite succeeded');

    my ($mode) = $dbh->selectrow_array('PRAGMA journal_mode=WAL');
    is(lc($mode), 'wal', 'SQLite WAL mode enabled');

    $dbh->do('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, worker INT NOT NULL, seq INT NOT NULL, label TEXT NOT NULL)');
    $dbh->do('CREATE TABLE fiber_log (id INTEGER PRIMARY KEY AUTOINCREMENT, worker INT NOT NULL, fiber INT NOT NULL, val TEXT NOT NULL)');
    $dbh->disconnect;
}

# Pre-freeze pool definition (immutable config; per-worker runtime state in %_POOLS)
our $POOL = DBI::MT::Pool->new(
    dsn             => $DSN,
    max_connections => 2,
    attr            => {
        RaiseError          => 1,
        PrintError          => 0,
        AutoCommit          => 1,
        sqlite_busy_timeout => 10_000,
        sqlite_unicode      => 1,
    },
    on_connect      => sub {
        my ($dbh) = @_;
        $dbh->do('PRAGMA busy_timeout = 10000');
        $dbh->do('PRAGMA synchronous = NORMAL');
    },
);

# Worker routine: concurrent WAL reads & busy_timeout writes
sub worker_wal_rw {
    my ($dsn, $wid, $iters) = @_;

    my $dbh = DBI->connect($dsn, '', '', {
        RaiseError          => 1,
        PrintError          => 0,
        AutoCommit          => 1,
        sqlite_busy_timeout => 15_000,
        sqlite_unicode      => ($wid % 2),
    }) or die "worker $wid connect failed: $DBI::errstr";

    my $ins = $dbh->prepare('INSERT INTO items (worker, seq, label) VALUES (?, ?, ?)');
    my $sel = $dbh->prepare('SELECT COUNT(*) FROM items WHERE worker = ?');
    my $col = $dbh->prepare('SELECT label FROM items WHERE worker = ? ORDER BY label COLLATE perl LIMIT 1');

    for my $i (1 .. $iters) {
        $ins->execute($wid, $i, sprintf('w%02d-s%03d', $wid, $i));
        if ($i % 5 == 0) {
            $sel->execute($wid);
            my ($cnt) = $sel->fetchrow_array;
            die "worker $wid expected count $i, got $cnt" if $cnt != $i;
        }
    }

    $col->execute($wid);
    my ($first_label) = $col->fetchrow_array;
    $ins->finish;
    $sel->finish;
    $col->finish;
    $dbh->disconnect;

    return "$wid:$iters:$first_label";
}

# Worker routine: DBI::MT::Pool + MT::Fiber coroutines against SQLite
sub worker_pool_fibers {
    my ($wid, $nfibers) = @_;

    my @fids;
    for my $f (1 .. $nfibers) {
        push @fids, MT::Fiber::schedule(sub {
            return $POOL->with_dbh(sub {
                my ($dbh) = @_;
                # Yield while holding the connection so other fibers contend and park
                MT::Fiber::pass();
                $dbh->do(
                    'INSERT INTO fiber_log (worker, fiber, val) VALUES (?, ?, ?)',
                    undef,
                    $wid, $f, "w$wid-f$f"
                );
                MT::Fiber::pass();
                my ($c) = $dbh->selectrow_array(
                    'SELECT COUNT(*) FROM fiber_log WHERE worker = ? AND fiber = ?',
                    undef,
                    $wid, $f
                );
                return $c;
            });
        });
    }

    MT::Fiber::run();
    my $sum = 0;
    $sum += MT::Fiber::join($_) for @fids;

    my $st = $POOL->stats;
    $POOL->disconnect_all;

    return join(':', $wid, $sum, $st->{created}, $st->{reused}, $st->{waits});
}

# 3. Freeze boot image with DBI + DBD::SQLite + DBI::MT::Pool loaded
MT::Image::freeze();
pass('MT::Image::freeze() succeeded with DBI, DBD::SQLite, and DBI::MT::Pool pre-loaded');

# 4. 8 concurrent MT::Worker threads doing WAL-mode reads & busy_timeout writes
my $num_workers = 8;
my $iters       = 25;
my @wids        = map { MT::Worker::spawn('main::worker_wal_rw', $DSN, $_, $iters) } 1 .. $num_workers;
my @results     = map { MT::Worker::join($_) } @wids;

is(scalar(@results), $num_workers, "all $num_workers WAL worker threads joined cleanly");
for my $idx (0 .. $num_workers - 1) {
    my $w = $idx + 1;
    is(
        $results[$idx],
        sprintf('%d:%d:w%02d-s001', $w, $iters, $w),
        "worker $w completed $iters writes/reads and COLLATE perl"
    );
}

# 5. DBI::MT::Pool + MT::Fiber coroutines across 4 workers x 6 fibers (max_connections => 2)
my $pool_workers = 4;
my $nfibers      = 6;
my @pwids        = map { MT::Worker::spawn('main::worker_pool_fibers', $_, $nfibers) } 1 .. $pool_workers;
my @presults     = map { MT::Worker::join($_) } @pwids;

is(scalar(@presults), $pool_workers, "all $pool_workers pool+fiber workers joined cleanly");
for my $idx (0 .. $pool_workers - 1) {
    my $w = $idx + 1;
    my ($rw, $sum, $created, $reused, $waits) = split /:/, $presults[$idx];
    is($rw, $w, "pool worker $w identity matches");
    is($sum, $nfibers, "pool worker $w all $nfibers fibers inserted and read back");
    ok($created >= 1 && $created <= 2, "pool worker $w respected max_connections=2 (created=$created)");
    ok($reused >= 1, "pool worker $w reused pooled SQLite connections (reused=$reused)");
    ok($waits >= 1, "pool worker $w parked/woke contending fibers (waits=$waits)");
}

# 6. Verify final database state from main interpreter
{
    my $dbh = DBI->connect($DSN, '', '', {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    });
    my ($item_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM items');
    is($item_count, $num_workers * $iters, 'items table has exact expected row count across 8 workers');

    my ($fiber_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM fiber_log');
    is($fiber_count, $pool_workers * $nfibers, 'fiber_log table has exact expected row count across pool+fiber workers');
    $dbh->disconnect;
}

done_testing();
