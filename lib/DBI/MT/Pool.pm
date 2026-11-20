package DBI::MT::Pool;

use strict;
use warnings;
use Carp qw(croak);
use DBI ();

our $VERSION = '0.01';

# Per-worker runtime pool state keyed by immutable pool ID.
# Package globals (`our`) get per-worker GP indirection in perl5-mt, so they
# remain freely mutable in workers after MT::Image::freeze(), unlike captured
# file-scoped `my` lexicals which freeze as SVf_IMMORTAL.
our %_POOLS;
our $_NEXT_ID = 0;

sub CLONE {
    %_POOLS = ();
    return;
}

sub new {
    my $class = shift;
    my %args  = (@_ == 1 && ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_;

    croak "DBI::MT::Pool->new: 'dsn' is required"
        unless defined $args{dsn} && length $args{dsn};

    my $max = exists $args{max_connections} ? $args{max_connections} : 8;
    croak "DBI::MT::Pool->new: 'max_connections' must be a positive integer"
        unless defined $max && $max =~ /^\d+$/ && $max > 0;

    my $attr = {};
    if (defined $args{attr}) {
        croak "DBI::MT::Pool->new: 'attr' must be a hash reference"
            unless ref($args{attr}) eq 'HASH';
        %$attr = %{ $args{attr} };
    }

    my $on_connect = $args{on_connect};
    if (defined $on_connect) {
        croak "DBI::MT::Pool->new: 'on_connect' must be a code reference"
            unless ref($on_connect) eq 'CODE';
    }

    my $ping = exists $args{ping_on_checkout} ? ($args{ping_on_checkout} ? 1 : 0) : 1;
    my $idle_timeout = exists $args{idle_timeout} ? $args{idle_timeout} : 300;
    if (defined $idle_timeout) {
        croak "DBI::MT::Pool->new: 'idle_timeout' must be non-negative"
            unless $idle_timeout >= 0;
    }

    my $id = ++$_NEXT_ID;

    return bless {
        id               => $id,
        dsn              => $args{dsn},
        user             => $args{user},
        pass             => $args{pass},
        attr             => $attr,
        max_connections  => int($max),
        ping_on_checkout => $ping,
        idle_timeout     => $idle_timeout,
        on_connect       => $on_connect,
    }, $class;
}

sub id              { $_[0]{id} }
sub dsn             { $_[0]{dsn} }
sub max_connections { $_[0]{max_connections} }

sub _state {
    my ($self) = @_;
    return $_POOLS{ $self->{id} } ||= {
        idle      => [],
        active    => 0,
        waiters   => [],
        created   => 0,
        reused    => 0,
        checkouts => 0,
        checkins  => 0,
        waits     => 0,
        discarded => 0,
        rollbacks => 0,
    };
}

sub _current_fiber {
    return defined(&MT::Fiber::current) ? MT::Fiber::current() : 0;
}

sub _wake_next {
    my ($self, $state) = @_;
    return unless defined(&MT::Fiber::wake);
    while (@{ $state->{waiters} }) {
        my $fid = shift @{ $state->{waiters} };
        my $ok  = eval { MT::Fiber::wake($fid); 1 };
        last if $ok;
    }
    return;
}

sub _connect {
    my ($self) = @_;
    # Copy attr into a fresh mutable hashref: $self->{attr} may be SVf_IMMORTAL
    # after MT::Image::freeze().
    my %attr = (
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        %{ $self->{attr} },
    );
    my $dbh = DBI->connect($self->{dsn}, $self->{user}, $self->{pass}, \%attr)
        or croak "DBI::MT::Pool: DBI->connect($self->{dsn}) failed: "
                 . ($DBI::errstr || 'unknown error');

    if (my $cb = $self->{on_connect}) {
        my $ok = eval { $cb->($dbh); 1 };
        if (!$ok) {
            my $err = $@;
            eval { $dbh->disconnect };
            die $err;
        }
    }
    return $dbh;
}

sub checkout {
    my ($self) = @_;
    my $state  = $self->_state;
    my $max    = $self->{max_connections};

    while ($state->{active} >= $max) {
        my $fid = _current_fiber();
        if ($fid && defined(&MT::Fiber::park)) {
            push @{ $state->{waiters} }, $fid;
            $state->{waits}++;
            my $ok = eval { MT::Fiber::park(); 1 };
            if (!$ok) {
                my $err = $@;
                @{ $state->{waiters} } = grep { $_ != $fid } @{ $state->{waiters} };
                croak "DBI::MT::Pool: pool exhausted (max_connections=$max) and cannot park fiber: $err";
            }
        }
        else {
            croak "DBI::MT::Pool: pool exhausted (max_connections=$max)";
        }
    }

    # Reserve slot before any DBI call that might yield in a fiber.
    $state->{active}++;

    my $now          = time();
    my $idle_timeout = $self->{idle_timeout};
    my $ping         = $self->{ping_on_checkout};
    my $dbh;

    while (@{ $state->{idle} }) {
        my $entry = pop @{ $state->{idle} };
        my ($cand, $ts) = @$entry;

        if ($idle_timeout && ($now - $ts) > $idle_timeout) {
            eval { $cand->disconnect };
            $state->{discarded}++;
            next;
        }

        my $alive = eval {
            $cand->{Active} && (!$ping || $cand->ping);
        };
        if ($alive) {
            $dbh = $cand;
            $state->{reused}++;
            last;
        }
        else {
            eval { $cand->disconnect };
            $state->{discarded}++;
        }
    }

    if (!$dbh) {
        my $ok = eval {
            $dbh = $self->_connect();
            1;
        };
        if (!$ok) {
            my $err = $@;
            $state->{active}--;
            $self->_wake_next($state);
            die $err;
        }
        $state->{created}++;
    }

    $state->{checkouts}++;
    return $dbh;
}

sub checkin {
    my ($self, $dbh) = @_;
    croak "DBI::MT::Pool: checkin requires a database handle"
        unless defined $dbh;

    my $state   = $self->_state;
    my $healthy = 1;

    if (eval { $dbh->{Active} }) {
        my $in_txn = eval { !$dbh->{AutoCommit} || $dbh->{BegunWork} };
        if ($in_txn) {
            my $rb_ok = eval { $dbh->rollback; 1 };
            $state->{rollbacks}++;
            if (!$rb_ok) {
                $healthy = 0;
            }
            if ($healthy && eval { !$dbh->{AutoCommit} }) {
                my $default_ac = exists $self->{attr}{AutoCommit}
                    ? $self->{attr}{AutoCommit}
                    : 1;
                if ($default_ac) {
                    eval { $dbh->{AutoCommit} = 1 };
                    $healthy = 0 if $@;
                }
            }
        }
    }
    else {
        $healthy = 0;
    }

    $state->{active}-- if $state->{active} > 0;
    $state->{checkins}++;

    if ($healthy && eval { $dbh->{Active} } && @{ $state->{idle} } < $self->{max_connections}) {
        push @{ $state->{idle} }, [ $dbh, time() ];
    }
    else {
        eval { $dbh->disconnect };
        $state->{discarded}++;
    }

    # Wake the next parked fiber after releasing the slot and returning $dbh
    # to the idle list (important when preemption is enabled).
    $self->_wake_next($state);
    return 1;
}

sub with_dbh {
    my ($self, $code) = @_;
    croak "DBI::MT::Pool: with_dbh requires a code reference"
        unless ref($code) eq 'CODE';

    my $dbh       = $self->checkout();
    my $wantarray = wantarray;
    my (@res, $res);

    my $ok = eval {
        if ($wantarray) {
            @res = $code->($dbh);
        }
        elsif (defined $wantarray) {
            $res = $code->($dbh);
        }
        else {
            $code->($dbh);
        }
        1;
    };
    my $err = $@;

    eval { $self->checkin($dbh) };

    if (!$ok) {
        die $err;
    }
    return $wantarray ? @res : $res;
}

sub stats {
    my ($self) = @_;
    my $state  = $_POOLS{ $self->{id} };
    return {
        max_connections => $self->{max_connections},
        idle            => $state ? scalar(@{ $state->{idle} })    : 0,
        active          => $state ? $state->{active}               : 0,
        waiters         => $state ? scalar(@{ $state->{waiters} }) : 0,
        created         => $state ? $state->{created}              : 0,
        reused          => $state ? $state->{reused}               : 0,
        checkouts       => $state ? $state->{checkouts}            : 0,
        checkins        => $state ? $state->{checkins}             : 0,
        waits           => $state ? $state->{waits}                : 0,
        discarded       => $state ? $state->{discarded}            : 0,
        rollbacks       => $state ? $state->{rollbacks}            : 0,
    };
}

sub disconnect_all {
    my ($self) = @_;
    my $state  = $_POOLS{ $self->{id} };
    return 0 unless $state;

    my $count = 0;
    while (my $entry = pop @{ $state->{idle} }) {
        my ($dbh) = @$entry;
        eval { $dbh->disconnect };
        $count++;
    }
    return $count;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT';
    my $id = eval { $self->{id} };
    return unless defined $id && exists $_POOLS{$id};
    eval { $self->disconnect_all() };
    delete $_POOLS{$id};
    return;
}

1;

__END__

=head1 NAME

DBI::MT::Pool - Freeze-safe, per-worker, fiber-aware DBI connection pool for perl5-mt

=head1 SYNOPSIS

    use DBI;
    use DBI::MT::Pool;

    # Construct once before MT::Image::freeze()
    our $POOL = DBI::MT::Pool->new(
        dsn              => 'dbi:SQLite:dbname=/path/to/app.db',
        user             => '',
        pass             => '',
        attr             => { RaiseError => 1, AutoCommit => 1 },
        max_connections  => 8,
        ping_on_checkout => 1,
        idle_timeout     => 300,
        on_connect       => sub {
            my ($dbh) = @_;
            $dbh->do('PRAGMA busy_timeout = 5000');
        },
    );

    MT::Image::freeze();

    # Inside an MT::Worker running MT::Fiber coroutines:
    my $row = $POOL->with_dbh(sub {
        my ($dbh) = @_;
        return $dbh->selectrow_arrayref('SELECT 1');
    });

=head1 DESCRIPTION

C<DBI::MT::Pool> provides a small per-worker connection pool for C<perl5-mt>
that also runs on stock Perl 5:

=over 4

=item *

B<Freeze-safe configuration>: A pool object stores only immutable configuration
and can be constructed before C<MT::Image::freeze()>. Per-worker runtime state
(idle handles, active count, fiber wait queue, and counters) lives in
C<our %DBI::MT::Pool::_POOLS> and is cleared in C<CLONE>.

=item *

B<Per-worker isolation>: Each C<MT::Worker> lazily opens and reuses its own
C<DBI> handles up to C<max_connections> without sharing handles across threads.

=item *

B<Cooperative C<MT::Fiber> scheduling>: When all C<max_connections> handles in
a worker are checked out, a scheduled C<MT::Fiber> parks via
C<MT::Fiber::park()> and is woken via C<MT::Fiber::wake()> when another fiber
returns a handle. Outside a scheduled fiber (or on stock Perl 5), exhausting
C<max_connections> croaks.

=back

=head1 METHODS

=over 4

=item new(%args)

Creates a pool configuration. Required: C<dsn>. Optional: C<user>, C<pass>,
C<attr> (hashref merged on top of C<RaiseError =E<gt> 1, PrintError =E<gt> 0,
AutoCommit =E<gt> 1>), C<max_connections> (default 8), C<ping_on_checkout>
(default 1), C<idle_timeout> in seconds (default 300; 0 disables), and
C<on_connect> (coderef invoked as C<$cb-E<gt>($dbh)> on each newly opened
connection).

=item with_dbh($coderef)

Checks out a handle, invokes C<$coderef-E<gt>($dbh)> preserving calling
context, and always checks the handle back in even if C<$coderef> dies.
Prefer C<with_dbh> over manual C<checkout>/C<checkin> to avoid leaking pool
slots on exceptions.

=item checkout() / checkin($dbh)

Manually acquire and return a handle. On C<checkin>, if the handle has an open
transaction (C<!AutoCommit> or C<BegunWork>), C<rollback> is attempted before
returning the handle to the idle list; unhealthy handles or failed rollbacks
are disconnected and discarded.

=item stats()

Returns a hashref of per-worker counters: C<max_connections>, C<idle>,
C<active>, C<waiters>, C<created>, C<reused>, C<checkouts>, C<checkins>,
C<waits>, C<discarded>, and C<rollbacks>.

=item disconnect_all()

Disconnects and removes all currently idle handles in the calling worker.

=back

=head1 CAVEATS

C<DBI::MT::Pool> does not share handles across OS threads, and it cannot make
a blocking C database driver non-blocking: while a driver executes a
synchronous query, the calling worker thread is occupied until the call
returns.

=head1 SEE ALSO

L<DBI>, L<DBI::DBD>

=cut
