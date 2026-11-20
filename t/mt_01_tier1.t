#!perl
use strict;
use warnings;

use Test::More;

BEGIN {
    plan skip_all => 'perl5-mt (MT) not available'
        unless eval { require MT; 1 };
}

use DBI;
use DBI::DBD;

# 1. Verify dbd_mt_threadsafe_defines() helper
is(
    dbd_mt_threadsafe_defines(),
    '-DPERL_XS_THREADSAFE=1',
    'dbd_mt_threadsafe_defines() returns -DPERL_XS_THREADSAFE=1 on perl5-mt'
);
{
    local $ENV{PERL_DBI_NO_MT} = 1;
    is(
        dbd_mt_threadsafe_defines(),
        '',
        'dbd_mt_threadsafe_defines() respects PERL_DBI_NO_MT'
    );
}

# 2. Verify Tier 1 threadsafe flags on static DBI XSUBs and dynamic _install_method CVs
my @xsubs = (
    'DBI::_new_handle',
    'DBI::_install_method',
    'DBI::_clone_dbis',
    'DBI::hash',
    'DBI::neat',
    'DBI::looks_like_number',
    'DBI::dr::connect',
    'DBI::db::prepare',
    'DBI::st::execute',
    'DBI::st::fetchrow_arrayref',
);

for my $name (@xsubs) {
    my $cv = do { no strict 'refs'; \&{$name} };
    ok(MT::XS::is_threadsafe($cv), "$name is MT::XS::is_threadsafe");
    ok(!MT::XS::is_remote($cv),    "$name is not MT::XS::is_remote");
}

# 3. Verify MT::Image::freeze() with DBI pre-loaded and concurrent workers
my $parent_dbistate = $DBI::_dbistate;
ok($parent_dbistate, "parent DBI::_dbistate is initialized ($parent_dbistate)");

# Exercise dispatch in parent before freeze so parent's ima_cache is populated
{
    my $dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1 });
    my $sth = $dbh->prepare('parent_q', {
        NAME => ['k', 'v'],
        rows => [ ['p1', 10], ['p2', 20] ],
    });
    $sth->execute;
    my $row = $sth->fetchrow_arrayref;
    is_deeply($row, ['p1', 10], 'parent DBI dispatch works before freeze');
    $sth->finish;
    $dbh->disconnect;
}

sub worker_task {
    my ($wid) = @_;
    my $safe   = MT::XS::is_threadsafe(\&DBI::db::prepare) ? 1 : 0;
    my $remote = MT::XS::is_remote(\&DBI::db::prepare)     ? 1 : 0;
    my $dbis   = $DBI::_dbistate || 0;

    my $dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1 });
    my $sth = $dbh->prepare("w_$wid", {
        NAME => ['id', 'val'],
        rows => [ [$wid, $wid * 10], [$wid, $wid * 100] ],
    });
    $sth->execute;
    my @got;
    while (my $r = $sth->fetchrow_arrayref) {
        push @got, "$r->[0]:$r->[1]";
    }
    $sth->finish;
    $dbh->disconnect;

    return join('|', $safe, $remote, $dbis, join(',', @got));
}

eval { MT::Image::freeze(); 1 }
    or fail("MT::Image::freeze() with DBI pre-loaded died: $@");
pass('MT::Image::freeze() succeeded with DBI pre-loaded');

my @workers = map { MT::Worker::spawn('main::worker_task', $_) } 1 .. 4;
my %seen_dbis;
for my $i (0 .. $#workers) {
    my $wid = $i + 1;
    my $res = MT::Worker::join($workers[$i]);
    my ($safe, $remote, $dbis, $rows) = split /\|/, $res, 4;
    is($safe,   1, "worker $wid sees DBI::db::prepare as threadsafe");
    is($remote, 0, "worker $wid sees DBI::db::prepare as local (not remote)");
    ok($dbis && $dbis != $parent_dbistate,
       "worker $wid has its own DBI::_dbistate ($dbis != $parent_dbistate)");
    $seen_dbis{$dbis}++;
    my $exp = "$wid:" . ($wid * 10) . ",$wid:" . ($wid * 100);
    is($rows, $exp, "worker $wid DBI dispatch/ima_cache returned expected rows");
}
is(scalar(keys %seen_dbis), 4, 'all 4 workers had distinct DBI::_dbistate pointers');

done_testing();
