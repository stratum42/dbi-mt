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
    unless (eval { require DBD::ODBC; 1 }) {
        plan skip_all => 'DBD::ODBC is not in @INC';
    }
    unless (eval { require DBI::MT::Pool; 1 }) {
        plan skip_all => 'DBI::MT::Pool is not available';
    }
}

# 1. Verify Tier 1 PERL_XS_THREADSAFE=1 flags on DBD::ODBC XSUBs
ok(
    MT::XS::is_threadsafe(\&DBD::ODBC::db::_login),
    'DBD::ODBC::db::_login is Tier 1 threadsafe'
);
ok(
    !MT::XS::is_remote(\&DBD::ODBC::db::_login),
    'DBD::ODBC::db::_login is not remote'
);
ok(
    MT::XS::is_threadsafe(\&DBD::ODBC::dr::_data_sources),
    'DBD::ODBC::dr::_data_sources is Tier 1 threadsafe'
);
ok(
    !MT::XS::is_remote(\&DBD::ODBC::dr::_data_sources),
    'DBD::ODBC::dr::_data_sources is not remote'
);
ok(
    MT::XS::is_threadsafe(\&DBD::ODBC::st::_prepare),
    'DBD::ODBC::st::_prepare is Tier 1 threadsafe'
);
ok(
    MT::XS::is_threadsafe(\&DBD::ODBC::db::_ExecDirect),
    'DBD::ODBC::db::_ExecDirect is Tier 1 threadsafe'
);

# 2. Detect SQLite ODBC driver for live-DSN concurrency tests
sub find_sqlite_odbc_driver {
    my @candidates = (
        $ENV{DBI_ODBC_SQLITE_DRIVER} ? ($ENV{DBI_ODBC_SQLITE_DRIVER}) : (),
        '/opt/homebrew/opt/sqliteodbc/lib/libsqlite3odbc.dylib',
        '/usr/local/opt/sqliteodbc/lib/libsqlite3odbc.dylib',
        '/opt/homebrew/lib/libsqlite3odbc.dylib',
        '/usr/local/lib/libsqlite3odbc.dylib',
        '/usr/lib/x86_64-linux-gnu/odbc/libsqlite3odbc.so',
        '/usr/lib/aarch64-linux-gnu/odbc/libsqlite3odbc.so',
        '/usr/lib64/libsqlite3odbc.so',
        '/usr/lib/libsqlite3odbc.so',
    );
    for my $p (@candidates) {
        return $p if defined($p) && -f $p;
    }
    return undef;
}

my $sqlite_drv = find_sqlite_odbc_driver();
my $tmpdir     = tempdir(CLEANUP => 1);
my $dbfile     = File::Spec->catfile($tmpdir, 'mt_odbc_test.db');

our $LIVE_DSN = '';
our $POOL;

if (defined $sqlite_drv) {
    $LIVE_DSN = "dbi:ODBC:DRIVER=$sqlite_drv;Database=$dbfile;Timeout=15000;";
    my $dbh = eval {
        DBI->connect($LIVE_DSN, '', '', {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
        });
    };
    if ($dbh) {
        ok($dbh, "pre-freeze DBI->connect via SQLite ODBC ($sqlite_drv) succeeded");
        $dbh->do('PRAGMA journal_mode=WAL');
        $dbh->do('PRAGMA busy_timeout=15000');
        $dbh->do('CREATE TABLE odbc_items (id INTEGER PRIMARY KEY AUTOINCREMENT, worker INT NOT NULL, seq INT NOT NULL, label TEXT NOT NULL)');
        $dbh->do('CREATE TABLE odbc_pool_log (id INTEGER PRIMARY KEY AUTOINCREMENT, worker INT NOT NULL, fiber INT NOT NULL, val TEXT NOT NULL)');
        $dbh->disconnect;

        $POOL = DBI::MT::Pool->new(
            dsn             => $LIVE_DSN,
            user            => '',
            pass            => '',
            max_connections => 2,
            attr            => {
                RaiseError => 1,
                PrintError => 0,
                AutoCommit => 1,
            },
            on_connect      => sub {
                my ($c) = @_;
                $c->do('PRAGMA busy_timeout=15000');
            },
        );
    } else {
        diag("SQLite ODBC driver found at $sqlite_drv but connect failed: $@");
        $LIVE_DSN = '';
    }
}

# Worker routine 1: install_driver('ODBC') + data_sources() after freeze
sub worker_driver_and_sources {
    my ($wid) = @_;
    my $drh = DBI->install_driver('ODBC')
        or die "worker $wid install_driver(ODBC) failed";
    my @ds = $drh->data_sources();
    # Verify per-worker ODBC driver handle is distinct and usable
    return "$wid:" . $drh->{Name} . ":" . scalar(@ds);
}

# Worker routine 2: live SQLite-over-ODBC concurrent reads & writes
sub worker_odbc_rw {
    my ($dsn, $wid, $iters) = @_;
    my $dbh = DBI->connect($dsn, '', '', {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }) or die "worker $wid ODBC connect failed: $DBI::errstr";

    $dbh->do('PRAGMA busy_timeout=15000');
    my $ins = $dbh->prepare('INSERT INTO odbc_items (worker, seq, label) VALUES (?, ?, ?)');
    my $sel = $dbh->prepare('SELECT COUNT(*) FROM odbc_items WHERE worker = ?');

    for my $i (1 .. $iters) {
        $ins->execute($wid, $i, sprintf('odbc-w%02d-s%03d', $wid, $i));
        if ($i % 5 == 0) {
            $sel->execute($wid);
            my ($cnt) = $sel->fetchrow_array;
            $sel->finish;
            die "worker $wid expected count $i, got $cnt" if $cnt != $i;
        }
    }

    $sel->execute($wid);
    my ($final_cnt) = $sel->fetchrow_array;
    $sel->finish;
    $ins->finish;
    undef $sel;
    undef $ins;
    $dbh->disconnect;

    return "$wid:$final_cnt";
}

# Worker routine 3: DBI::MT::Pool + MT::Fiber over ODBC
sub worker_odbc_pool_fibers {
    my ($wid, $nfibers) = @_;
    my @fids;
    for my $f (1 .. $nfibers) {
        push @fids, MT::Fiber::schedule(sub {
            return $POOL->with_dbh(sub {
                my ($dbh) = @_;
                MT::Fiber::pass();
                $dbh->do(
                    'INSERT INTO odbc_pool_log (worker, fiber, val) VALUES (?, ?, ?)',
                    undef,
                    $wid, $f, "w$wid-f$f"
                );
                MT::Fiber::pass();
                my ($c) = $dbh->selectrow_array(
                    'SELECT COUNT(*) FROM odbc_pool_log WHERE worker = ? AND fiber = ?',
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

# 3. Freeze boot image with DBI + DBD::ODBC + DBI::MT::Pool loaded
MT::Image::freeze();
pass('MT::Image::freeze() succeeded with DBI, DBD::ODBC, and DBI::MT::Pool pre-loaded');

# 4. 8 concurrent MT::Worker threads calling install_driver('ODBC') and data_sources()
{
    my $num_workers = 8;
    my @wids    = map { MT::Worker::spawn('main::worker_driver_and_sources', $_) } 1 .. $num_workers;
    my @results = map { MT::Worker::join($_) } @wids;

    is(scalar(@results), $num_workers, "all $num_workers driver/data_sources workers joined cleanly");
    for my $idx (0 .. $num_workers - 1) {
        my $w = $idx + 1;
        like($results[$idx], qr/^\Q$w\E:ODBC:\d+$/, "worker $w installed ODBC driver and queried data_sources");
    }
}

# 5. Live DSN concurrency + DBI::MT::Pool tests (skip only if no ODBC driver is installed)
SKIP: {
    skip 'No SQLite ODBC driver available on host for live DSN tests', 1
        unless length $LIVE_DSN;

    my $num_workers = 8;
    my $iters       = 15;
    my @wids    = map { MT::Worker::spawn('main::worker_odbc_rw', $LIVE_DSN, $_, $iters) } 1 .. $num_workers;
    my @results = map { MT::Worker::join($_) } @wids;

    is(scalar(@results), $num_workers, "all $num_workers live ODBC R/W workers joined cleanly");
    for my $idx (0 .. $num_workers - 1) {
        my $w = $idx + 1;
        is($results[$idx], "$w:$iters", "live ODBC worker $w inserted and verified $iters rows");
    }

    my $pool_workers = 4;
    my $nfibers      = 4;
    my @pwids    = map { MT::Worker::spawn('main::worker_odbc_pool_fibers', $_, $nfibers) } 1 .. $pool_workers;
    my @presults = map { MT::Worker::join($_) } @pwids;

    is(scalar(@presults), $pool_workers, "all $pool_workers ODBC pool+fiber workers joined cleanly");
    for my $idx (0 .. $pool_workers - 1) {
        my $w = $idx + 1;
        my ($rw, $sum, $created, $reused, $waits) = split /:/, $presults[$idx];
        is($rw, $w, "ODBC pool worker $w identity matches");
        is($sum, $nfibers, "ODBC pool worker $w all $nfibers fibers inserted and read back");
        ok($created >= 1 && $created <= 2, "ODBC pool worker $w respected max_connections=2 (created=$created)");
        ok($reused >= 1, "ODBC pool worker $w reused pooled ODBC connections (reused=$reused)");
        ok($waits >= 1, "ODBC pool worker $w parked/woke contending fibers (waits=$waits)");
    }

    my $dbh = DBI->connect($LIVE_DSN, '', '', {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    });
    my ($item_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM odbc_items');
    is($item_count, $num_workers * $iters, 'odbc_items has exact expected row count across 8 workers');

    my ($pool_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM odbc_pool_log');
    is($pool_count, $pool_workers * $nfibers, 'odbc_pool_log has exact expected row count across pool+fiber workers');
    $dbh->disconnect;
}

done_testing();
