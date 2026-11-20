#!perl
use strict;
use warnings;
use Test::More;

use DBI;
use DBD::NullP;
use DBI::MT::Pool;

# ---- 1. Constructor validation ---------------------------------------------

{
    ok(!eval { DBI::MT::Pool->new(); 1 }, 'new() without dsn croaks');
    like($@, qr/dsn.*required/i, '... with informative message');

    ok(!eval { DBI::MT::Pool->new(dsn => 'dbi:NullP:', max_connections => 0); 1 },
       'new() with max_connections => 0 croaks');

    ok(!eval { DBI::MT::Pool->new(dsn => 'dbi:NullP:', attr => 'bad'); 1 },
       'new() with non-hashref attr croaks');

    ok(!eval { DBI::MT::Pool->new(dsn => 'dbi:NullP:', on_connect => 'bad'); 1 },
       'new() with non-coderef on_connect croaks');
}

# ---- 2. Synchronous checkout / checkin / reuse / on_connect / stats --------

{
    my $connect_calls = 0;
    my $pool = DBI::MT::Pool->new(
        dsn              => 'dbi:NullP:',
        max_connections  => 2,
        ping_on_checkout => 1,
        idle_timeout     => 300,
        on_connect       => sub {
            my ($dbh) = @_;
            $connect_calls++;
            $dbh->{private_pool_tag} = "conn-$connect_calls";
        },
    );

    my $st = $pool->stats();
    is($st->{max_connections}, 2, 'stats max_connections == 2');
    is($st->{created},   0, 'initial created == 0');
    is($st->{idle},      0, 'initial idle == 0');
    is($st->{active},    0, 'initial active == 0');

    my $dbh1 = $pool->checkout();
    ok($dbh1 && $dbh1->{Active}, 'checkout returns active dbh');
    is($connect_calls, 1, 'on_connect called once on first checkout');
    is($dbh1->{private_pool_tag}, 'conn-1', 'on_connect customized dbh');

    $st = $pool->stats();
    is($st->{active},    1, 'active == 1 after checkout');
    is($st->{idle},      0, 'idle == 0 after checkout');
    is($st->{created},   1, 'created == 1');
    is($st->{checkouts}, 1, 'checkouts == 1');

    $pool->checkin($dbh1);
    $st = $pool->stats();
    is($st->{active},   0, 'active == 0 after checkin');
    is($st->{idle},     1, 'idle == 1 after checkin');
    is($st->{checkins}, 1, 'checkins == 1');

    my $dbh2 = $pool->checkout();
    is($dbh2->{private_pool_tag}, 'conn-1', 'second checkout reuses idle dbh');
    is($connect_calls, 1, 'on_connect not called again on reuse');
    $pool->checkin($dbh2);

    $st = $pool->stats();
    is($st->{created},   1, 'created still 1 after reuse');
    is($st->{reused},    1, 'reused == 1');
    is($st->{checkouts}, 2, 'checkouts == 2');
    is($st->{checkins},  2, 'checkins == 2');

    # Exhaustion outside a fiber croaks cleanly
    my $a = $pool->checkout();
    my $b = $pool->checkout();
    is($connect_calls, 2, 'second concurrent checkout opens second connection');
    ok(!eval { $pool->checkout(); 1 }, 'third checkout exceeds max_connections and croaks');
    like($@, qr/pool exhausted/i, '... with pool exhausted message');
    $pool->checkin($b);
    $pool->checkin($a);

    # disconnect_all()
    my $closed = $pool->disconnect_all();
    is($closed, 2, 'disconnect_all closed 2 idle handles');
    $st = $pool->stats();
    is($st->{idle}, 0, 'idle == 0 after disconnect_all');

    my $dbh3 = $pool->checkout();
    is($connect_calls, 3, 'checkout after disconnect_all creates fresh connection');
    $pool->checkin($dbh3);
    $pool->disconnect_all();
}

# ---- 3. with_dbh context preservation & exception safety -------------------

{
    my $pool = DBI::MT::Pool->new(
        dsn             => 'dbi:NullP:',
        max_connections => 1,
    );

    my $scalar_val = $pool->with_dbh(sub {
        my ($dbh) = @_;
        ok($dbh->{Active}, 'with_dbh receives active dbh');
        return 'scalar-ok';
    });
    is($scalar_val, 'scalar-ok', 'with_dbh preserves scalar context');

    my @list_val = $pool->with_dbh(sub {
        return ('a', 'b', 'c');
    });
    is_deeply(\@list_val, [qw(a b c)], 'with_dbh preserves list context');

    my $void_ran = 0;
    $pool->with_dbh(sub { $void_ran = 1 });
    is($void_ran, 1, 'with_dbh runs in void context');

    # Exception safety with string error
    my $ok = eval {
        $pool->with_dbh(sub {
            die "boom-from-callback\n";
        });
        1;
    };
    ok(!$ok, 'with_dbh propagates string exception');
    is($@, "boom-from-callback\n", '... with original $@ intact');

    my $st = $pool->stats();
    is($st->{active}, 0, 'handle checked back in after exception');
    is($st->{idle},   1, 'handle returned to idle pool after exception');

    # Exception safety with object exception
    $ok = eval {
        $pool->with_dbh(sub {
            die bless { code => 42 }, 'TestPoolErr';
        });
        1;
    };
    ok(!$ok, 'with_dbh propagates object exception');
    isa_ok($@, 'TestPoolErr', '... exception object intact');
    is($@->{code}, 42, '... exception payload intact');
    is($pool->stats()->{active}, 0, 'active == 0 after object exception');

    $pool->disconnect_all();
}

# ---- 4. Dirty checkin rollback & unhealthy handle discard ------------------

{
    package TestMockDBH;
    sub new {
        my ($class, %opt) = @_;
        return bless {
            Active        => exists $opt{Active}     ? $opt{Active}     : 1,
            AutoCommit    => exists $opt{AutoCommit} ? $opt{AutoCommit} : 1,
            BegunWork     => $opt{BegunWork} || 0,
            fail_rollback => $opt{fail_rollback} || 0,
            rollbacks     => 0,
            disconnected  => 0,
        }, $class;
    }
    sub rollback {
        my ($self) = @_;
        $self->{rollbacks}++;
        die "simulated rollback failure\n" if $self->{fail_rollback};
        $self->{BegunWork}  = 0;
        $self->{AutoCommit} = 1;
        return 1;
    }
    sub disconnect {
        my ($self) = @_;
        $self->{Active} = 0;
        $self->{disconnected}++;
        return 1;
    }
    sub ping { $_[0]{Active} ? 1 : 0 }
}

{
    my $pool = DBI::MT::Pool->new(
        dsn             => 'dbi:NullP:',
        max_connections => 2,
    );

    # Dirty handle with open transaction: rollback succeeds, handle returned to idle
    my $dirty = TestMockDBH->new(AutoCommit => 0, BegunWork => 1);
    $pool->checkin($dirty);
    is($dirty->{rollbacks},  1, 'dirty checkin triggered rollback()');
    is($dirty->{AutoCommit}, 1, 'AutoCommit restored after rollback');
    is($pool->stats()->{rollbacks}, 1, 'stats rollbacks == 1');
    is($pool->stats()->{idle},      1, 'rolled-back handle returned to idle');

    # Dirty handle whose rollback fails: disconnected and discarded
    my $broken = TestMockDBH->new(AutoCommit => 0, BegunWork => 1, fail_rollback => 1);
    $pool->checkin($broken);
    is($broken->{rollbacks},    1, 'broken handle attempted rollback()');
    is($broken->{disconnected}, 1, 'broken handle disconnected after rollback failure');
    is($pool->stats()->{rollbacks}, 2, 'stats rollbacks == 2');
    is($pool->stats()->{discarded}, 1, 'stats discarded == 1');
    is($pool->stats()->{idle},      1, 'broken handle not added to idle');

    # Inactive handle: discarded
    my $dead = TestMockDBH->new(Active => 0);
    $pool->checkin($dead);
    is($pool->stats()->{discarded}, 2, 'inactive handle discarded');
    is($pool->stats()->{idle},      1, 'inactive handle not added to idle');

    $pool->disconnect_all();
}

# ---- 5. perl5-mt: pre-freeze pool + 4 MT::Worker x 8 MT::Fiber contention --

our $FROZEN_POOL;
our $WORKER_OK_COUNT = 0;

sub pool_worker_main {
    my ($worker_id) = @_;

    # CLONE must have cleared %_POOLS so each worker starts completely isolated
    my $init = $FROZEN_POOL->stats();
    die "worker $worker_id did not start with empty pool (created=$init->{created}, idle=$init->{idle})\n"
        if $init->{created} != 0 || $init->{idle} != 0 || $init->{active} != 0;

    my $max_seen_active = 0;
    my @fids;

    for my $f (1 .. 8) {
        push @fids, MT::Fiber::schedule(sub {
            my $done = 0;
            for my $iter (1 .. 3) {
                my $val = $FROZEN_POOL->with_dbh(sub {
                    my ($dbh) = @_;
                    my $st = $FROZEN_POOL->stats();
                    $max_seen_active = $st->{active}
                        if $st->{active} > $max_seen_active;
                    die "active=$st->{active} exceeded max_connections=2\n"
                        if $st->{active} > 2;

                    my $sth = $dbh->prepare("SELECT $worker_id, $f, $iter");
                    $sth->execute();

                    # Yield while holding the handle to force sibling fibers to contend & park
                    MT::Fiber::pass();

                    $sth->finish();
                    return "$worker_id:$f:$iter";
                });
                die "unexpected return '$val'\n" unless $val eq "$worker_id:$f:$iter";
                $done++;
            }
            return $done;
        });
    }

    my $finished = MT::Fiber::run();
    die "expected 8 finished fibers, got $finished\n" unless $finished == 8;

    my $total_iters = 0;
    for my $fid (@fids) {
        $total_iters += MT::Fiber::join($fid);
    }

    my $st = $FROZEN_POOL->stats();
    my $closed = $FROZEN_POOL->disconnect_all();
    my $after  = $FROZEN_POOL->stats();

    return join(' ',
        "worker=$worker_id",
        "iters=$total_iters",
        "created=$st->{created}",
        "reused=$st->{reused}",
        "checkouts=$st->{checkouts}",
        "checkins=$st->{checkins}",
        "waits=$st->{waits}",
        "active=$st->{active}",
        "waiters=$st->{waiters}",
        "max_active=$max_seen_active",
        "closed=$closed",
        "after_idle=$after->{idle}",
    );
}

SKIP: {
    my $has_mt = defined(&MT::Image::freeze)
              && defined(&MT::Worker::spawn)
              && defined(&MT::Fiber::schedule);
    skip 'perl5-mt MT::Image/MT::Worker/MT::Fiber not available on stock Perl', 20
        unless $has_mt;

    # Construct pool BEFORE MT::Image::freeze()
    $FROZEN_POOL = DBI::MT::Pool->new(
        dsn              => 'dbi:NullP:',
        attr             => { RaiseError => 1, AutoCommit => 1 },
        max_connections  => 2,
        ping_on_checkout => 1,
        idle_timeout     => 300,
    );

    # Warm one connection in parent before freeze to verify CLONE clears it in workers
    $FROZEN_POOL->with_dbh(sub { my ($dbh) = @_; $dbh->ping });
    is($FROZEN_POOL->stats()->{idle}, 1, 'parent has 1 idle handle before freeze');

    MT::Image::freeze() unless MT::Image::frozen();
    ok(MT::Image::frozen(), 'MT::Image::freeze() succeeded with DBI::MT::Pool pre-created');

    my @wids = map { MT::Worker::spawn('main::pool_worker_main', $_) } 1 .. 4;
    my @results = map { MT::Worker::join($_) } @wids;

    is(scalar(@results), 4, 'all 4 MT::Worker threads joined');

    for my $i (0 .. 3) {
        my $res = $results[$i];
        my %kv = map { split /=/, $_, 2 } split /\s+/, $res;
        my $w  = $i + 1;
        is($kv{iters},      24, "worker $w completed 8 fibers x 3 iters = 24");
        ok($kv{created} >= 1 && $kv{created} <= 2,
           "worker $w created $kv{created} <= 2 connections");
        ok($kv{waits} > 0,
           "worker $w fibers contended and parked (waits=$kv{waits})");
        is("$kv{checkouts}/$kv{checkins}/$kv{active}/$kv{waiters}/$kv{max_active}/$kv{after_idle}",
           "24/24/0/0/2/0",
           "worker $w pool invariants exact ($res)");
    }

    # Parent pool remains intact and independent
    is($FROZEN_POOL->stats()->{idle}, 1, 'parent pool untouched by workers');
    $FROZEN_POOL->disconnect_all();
}

done_testing();
