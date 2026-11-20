#!perl
use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile tempdir);
use Config;

BEGIN {
    unless (defined &MT::Image::freeze && defined &MT::Worker::spawn) {
        plan skip_all => 'Requires perl5-mt (MT::Image and MT::Worker)';
    }
}

sub run_child {
    my ($code, %env_override) = @_;
    my ($fh, $filename) = tempfile(UNLINK => 1, SUFFIX => '.pl');
    print $fh $code;
    close $fh or die "close $filename: $!";

    local %ENV = (%ENV, %env_override);
    my @cmd = ($^X, (map { "-I$_" } @INC), $filename);
    my $out = '';
    my $pid = open(my $pipe, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>&', \*STDOUT) or die "dup stderr: $!";
        exec(@cmd) or die "exec failed: $!";
    }
    {
        local $/;
        $out = <$pipe>;
    }
    close $pipe;
    my $status = $?;
    return ($status, $out);
}

# ---------------------------------------------------------------------------
# Subtest 1: Pre-freeze `use DBI` + bundled drivers + 16 concurrent workers
#            + repeated spawn/join cycles
# ---------------------------------------------------------------------------
subtest 'pre-freeze DBI + 16 workers (NullP, Sponge, ExampleP, Mem, DBM) + repeated cycles' => sub {
    my $base_tmp = tempdir(CLEANUP => 1);
    my ($status, $out) = run_child(<<"CODE");
use strict;
use warnings;
use File::Spec;
use DBI;
use DBD::NullP;
use DBD::Sponge;
use DBD::ExampleP;
use DBD::Mem;
use DBD::DBM;

my \$BASE_TMP = '$base_tmp';

# Touch DBI->internal (DBD::Switch::dr) before freeze to verify CLONE clears it cleanly
my \$switch = DBI->internal;
die "no switch drh" unless \$switch;

sub worker_main {
    my (\$id) = \@_;

    # Verify per-worker \$DBI::neat_maxlen isolation
    \$DBI::neat_maxlen = 50 + \$id;
    die "neat_maxlen mismatch: \$DBI::neat_maxlen" unless \$DBI::neat_maxlen == 50 + \$id;

    # Verify DBD::Switch::dr works post-freeze in worker
    my \$sw = DBI->internal;
    die "worker \$id: no switch drh" unless \$sw;

    # 1. DBD::NullP: connect, prepare, execute, RaiseError/err/errstr/state, \$DBI::lasth
    {
        my \$dbh = DBI->connect('dbi:NullP:', '', '', { RaiseError => 1, PrintError => 0 });
        die "NullP connect failed" unless \$dbh;
        my \$sth = \$dbh->prepare("SELECT \$id");
        \$sth->execute();
        my \$row = \$sth->fetchrow_arrayref();
        die "NullP unexpected row" if defined \$row;
        \$sth->finish();

        # Trigger error to test RaiseError, err, errstr, state, \$DBI::lasth
        my \$raised = 0;
        eval { \$dbh->set_err(42 + \$id, "err_\$id", "S1000"); };
        \$raised = 1 if \$\@ && \$\@ =~ /err_\$id/;
        die "RaiseError did not fire for worker \$id (\$\@)" unless \$raised;
        die "dbh->err mismatch" unless (\$dbh->err || 0) == 42 + \$id;
        die "dbh->errstr mismatch" unless (\$dbh->errstr || '') eq "err_\$id";
        die "dbh->state mismatch" unless (\$dbh->state || '') eq "S1000";
        die "DBI::err mismatch" unless (\$DBI::err || 0) == 42 + \$id;
        die "DBI::errstr mismatch" unless (\$DBI::errstr || '') eq "err_\$id";
        die "DBI::state mismatch" unless (\$DBI::state || '') eq "S1000";
        die "DBI::lasth not defined" unless defined \$DBI::lasth;
        \$dbh->disconnect();
    }

    # 2. DBD::Sponge: prepare with rows, fetchrow_arrayref, fetchall_arrayref
    {
        my \$dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1, PrintError => 0 });
        my \$sth1 = \$dbh->prepare('sponge1', {
            rows => [ [ \$id, "a_\$id" ], [ \$id + 100, "b_\$id" ] ],
            NAME => [ 'id', 'label' ],
        });
        \$sth1->execute();
        my \$r1 = \$sth1->fetchrow_arrayref();
        die "Sponge fetchrow_arrayref failed" unless \$r1 && \$r1->[0] == \$id && \$r1->[1] eq "a_\$id";
        my \$r2 = \$sth1->fetchrow_arrayref();
        die "Sponge second row failed" unless \$r2 && \$r2->[0] == \$id + 100;
        \$sth1->finish();

        my \$sth2 = \$dbh->prepare('sponge2', {
            rows => [ [ 1, 'x' ], [ 2, 'y' ], [ 3, 'z' ] ],
            NAME => [ 'k', 'v' ],
        });
        \$sth2->execute();
        my \$all = \$sth2->fetchall_arrayref();
        die "Sponge fetchall_arrayref count" unless \$all && scalar(\@\$all) == 3;
        \$dbh->disconnect();
    }

    # 3. DBD::ExampleP: connect, prepare, execute, fetchall_arrayref
    {
        my \$dbh = DBI->connect('dbi:ExampleP:', '', '', { RaiseError => 1, PrintError => 0 });
        my \$sth = \$dbh->prepare("SELECT name, size FROM .");
        \$sth->execute();
        my \$rows = \$sth->fetchall_arrayref();
        die "ExampleP returned no rows" unless \$rows && scalar(\@\$rows) > 0;
        \$dbh->disconnect();
    }

    # 4. DBD::Mem: CREATE TABLE, INSERT, SELECT with fetchall_arrayref
    {
        my \$dbh = DBI->connect('dbi:Mem:', '', '', { RaiseError => 1, PrintError => 0 });
        \$dbh->do("CREATE TABLE items (id INT, val CHAR(20))");
        my \$ins = \$dbh->prepare("INSERT INTO items (id, val) VALUES (?, ?)");
        \$ins->execute(\$id, "mem_\$id");
        \$ins->execute(\$id * 2, "mem2_\$id");
        my \$sel = \$dbh->prepare("SELECT id, val FROM items ORDER BY id");
        \$sel->execute();
        my \$rows = \$sel->fetchall_arrayref();
        die "Mem row count mismatch" unless \$rows && scalar(\@\$rows) == 2;
        die "Mem row 0 mismatch" unless \$rows->[0][0] == \$id && \$rows->[0][1] eq "mem_\$id";
        \$dbh->disconnect();
    }

    # 5. DBD::DBM: worker-private directory, CREATE TABLE, INSERT, SELECT
    {
        my \$wdir = File::Spec->catdir(\$BASE_TMP, "w_\${id}_" . int(rand(1_000_000)));
        mkdir \$wdir or die "mkdir \$wdir: \$!";
        my \$dbh = DBI->connect("dbi:DBM:f_dir=\$wdir", '', '', { RaiseError => 1, PrintError => 0 });
        \$dbh->do("CREATE TABLE kv (k TEXT, v TEXT)");
        my \$ins = \$dbh->prepare("INSERT INTO kv (k, v) VALUES (?, ?)");
        \$ins->execute("k_\$id", "v_\$id");
        my \$sel = \$dbh->prepare("SELECT k, v FROM kv WHERE k = ?");
        \$sel->execute("k_\$id");
        my \$row = \$sel->fetchrow_arrayref();
        die "DBM fetch mismatch" unless \$row && \$row->[0] eq "k_\$id" && \$row->[1] eq "v_\$id";
        \$sel->finish();
        \$dbh->do("DROP TABLE kv");
        \$dbh->disconnect();
    }

    return "ok:\$id:\$DBI::neat_maxlen";
}

sub cycle_worker {
    my (\$cycle, \$id) = \@_;
    my \$dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1, PrintError => 0 });
    my \$sth = \$dbh->prepare('c', { rows => [ [ \$cycle, \$id ] ], NAME => [ 'c', 'i' ] });
    \$sth->execute();
    my \$r = \$sth->fetchrow_arrayref();
    die "cycle mismatch" unless \$r && \$r->[0] == \$cycle && \$r->[1] == \$id;
    \$dbh->disconnect();
    return "c\${cycle}_w\${id}";
}

MT::Image::freeze();

# 16 concurrent workers
my \@wids = map { MT::Worker::spawn('main::worker_main', \$_) } 1 .. 16;
my \@res  = map { MT::Worker::join(\$_) } \@wids;
print "WORKERS=", join(",", \@res), "\\n";

# Repeated spawn/join cycles (5 rounds x 8 workers)
my \$cycle_ok = 0;
for my \$c (1 .. 5) {
    my \@cw = map { MT::Worker::spawn('main::cycle_worker', \$c, \$_) } 1 .. 8;
    my \@cr = map { MT::Worker::join(\$_) } \@cw;
    for my \$i (0 .. 7) {
        die "bad cycle result: \$cr[\$i]" unless \$cr[\$i] eq "c\${c}_w" . (\$i + 1);
        \$cycle_ok++;
    }
}
print "CYCLES=\$cycle_ok\\n";
CODE

    is($status, 0, 'pre-freeze 16-worker child exited cleanly') or diag($out);
    like($out, qr/^WORKERS=ok:1:51,.*ok:16:66$/m, 'all 16 concurrent workers passed all 5 drivers + neat_maxlen isolation');
    like($out, qr/^CYCLES=40$/m, '5 repeated spawn/join cycles x 8 workers passed cleanly');
};

# ---------------------------------------------------------------------------
# Subtest 2: Post-freeze `require DBI` concurrently inside 8+ workers
# ---------------------------------------------------------------------------
subtest 'post-freeze concurrent require DBI in 10 workers' => sub {
    my ($status, $out) = run_child(<<'CODE');
use strict;
use warnings;

sub late_load_worker {
    my ($id) = @_;
    require DBI;
    my $dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1, PrintError => 0 });
    my $sth = $dbh->prepare('late', {
        rows => [ [ $id, $id * 10 ] ],
        NAME => [ 'id', 'val' ],
    });
    $sth->execute();
    my $row = $sth->fetchrow_arrayref();
    die "late_load row mismatch" unless $row && $row->[0] == $id && $row->[1] == $id * 10;
    $dbh->disconnect();
    return "late:$id:$row->[1]";
}

MT::Image::freeze();

my @wids = map { MT::Worker::spawn('main::late_load_worker', $_) } 1 .. 10;
my @res  = map { MT::Worker::join($_) } @wids;
print "LATE=", join(",", @res), "\n";
CODE

    is($status, 0, 'post-freeze require DBI child exited cleanly') or diag($out);
    like($out, qr/^LATE=late:1:10,.*late:10:100$/m, 'all 10 workers concurrently loaded DBI post-freeze');
};

# ---------------------------------------------------------------------------
# Subtest 3: DBI::PurePerl under MT::Image::freeze() + 8 concurrent workers
# ---------------------------------------------------------------------------
subtest 'DBI::PurePerl pre-freeze + 8 concurrent workers' => sub {
    my ($status, $out) = run_child(<<'CODE', DBI_PUREPERL => 2);
use strict;
use warnings;
use DBI;
use DBD::NullP;
use DBD::Sponge;
use DBD::Mem;

die "Expected DBI::PurePerl mode" unless $DBI::PurePerl;

sub pp_worker {
    my ($id) = @_;
    die "worker $id: not in PurePerl mode" unless $DBI::PurePerl;

    my $dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1, PrintError => 0 });
    my $sth = $dbh->prepare('pp', {
        rows => [ [ $id, "pp_$id" ] ],
        NAME => [ 'id', 'txt' ],
    });
    $sth->execute();
    my $row = $sth->fetchrow_arrayref();
    die "PP sponge mismatch" unless $row && $row->[0] == $id && $row->[1] eq "pp_$id";
    $dbh->disconnect();

    my $mdbh = DBI->connect('dbi:Mem:', '', '', { RaiseError => 1, PrintError => 0 });
    $mdbh->do("CREATE TABLE t (n INT)");
    $mdbh->do("INSERT INTO t (n) VALUES ($id)");
    my $msth = $mdbh->prepare("SELECT n FROM t");
    $msth->execute();
    my $mrow = $msth->fetchrow_arrayref();
    die "PP Mem mismatch" unless $mrow && $mrow->[0] == $id;
    $mdbh->disconnect();

    return "pp:$id";
}

MT::Image::freeze();

my @wids = map { MT::Worker::spawn('main::pp_worker', $_) } 1 .. 8;
my @res  = map { MT::Worker::join($_) } @wids;
print "PP=", join(",", @res), "\n";
CODE

    is($status, 0, 'DBI::PurePerl child exited cleanly') or diag($out);
    like($out, qr/^PP=pp:1,.*pp:8$/m, 'all 8 workers succeeded under DBI::PurePerl after freeze');
};

done_testing();
