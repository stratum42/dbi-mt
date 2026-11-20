#!perl
use strict;
use warnings;

use Test::More;
use Time::HiRes qw(time);
use DBI qw(:preparse_flags);

my $has_mt = eval { require MT; 1 } ? 1 : 0;

# ---------------------------------------------------------------------------
# 1. Runtime introspection: DBI::mt_arch_info()
# ---------------------------------------------------------------------------
my $info = DBI::mt_arch_info();
is(ref($info), 'HASH', 'DBI::mt_arch_info() returns a hashref');
for my $k (qw(arch simd cacheline force_scalar ebcdic)) {
    ok(exists $info->{$k}, "mt_arch_info has key '$k'");
}
like($info->{arch}, qr/^(?:arm64|amd64|ppc64le|ppc64|ppc|s390x|generic)$/,
    "arch is recognized ($info->{arch})");
like($info->{simd}, qr/^(?:neon|avx2|sse2|vsx|altivec|vx|scalar)$/,
    "simd backend is recognized ($info->{simd})");
ok($info->{cacheline} == 64 || $info->{cacheline} == 128 || $info->{cacheline} == 256,
    "cacheline size is valid ($info->{cacheline})");
ok($info->{force_scalar} == 0 || $info->{force_scalar} == 1,
    "force_scalar is boolean ($info->{force_scalar})");
ok($info->{ebcdic} == 0 || $info->{ebcdic} == 1,
    "ebcdic is boolean ($info->{ebcdic})");

if ($info->{force_scalar} || $info->{ebcdic}) {
    is($info->{simd}, 'scalar', 'simd reports scalar when force_scalar or ebcdic is active');
}

if ($has_mt) {
    for my $name (qw(
        DBI::mt_arch_info
        DBI::_mt_rtrim_spaces
        DBI::_mt_scan_sql_plain
        DBI::_mt_scan_nonprint_or_quote
    )) {
        my $cv = do { no strict 'refs'; \&{$name} };
        ok(MT::XS::is_threadsafe($cv), "$name is MT::XS::is_threadsafe");
        ok(!MT::XS::is_remote($cv),    "$name is not MT::XS::is_remote");
    }
}

# Verify PERL_FORCE_SCALAR=1 and PERL_DBI_FORCE_SCALAR=1 in child processes
my @inc_flags = map { "-I$_" } @INC;
for my $env_var (qw(PERL_FORCE_SCALAR PERL_DBI_FORCE_SCALAR)) {
    local $ENV{$env_var} = '1';
    my $out = '';
    open my $fh, '-|', $^X, @inc_flags, '-MDBI', '-e',
        'my $i = DBI::mt_arch_info(); print "$i->{simd}|$i->{force_scalar}|$i->{arch}|$i->{cacheline}\n"'
        or die "spawn failed: $!";
    $out = do { local $/; <$fh> };
    close $fh;
    chomp $out;
    my ($c_simd, $c_fs, $c_arch, $c_cl) = split /\|/, $out;
    is($c_simd, 'scalar', "$env_var=1 forces simd=scalar");
    is($c_fs,   1,        "$env_var=1 sets force_scalar=1");
    is($c_arch, $info->{arch},      "$env_var=1 preserves arch");
    is($c_cl,   $info->{cacheline}, "$env_var=1 preserves cacheline");
}

# Helper to create an SvOOK unaligned string with leading offset 0..31
sub make_unaligned {
    my ($offset, $payload) = @_;
    my $s = ('Z' x $offset) . $payload;
    substr($s, 0, $offset, '') if $offset > 0; # triggers SvOOK offset in-place
    return $s;
}

# ---------------------------------------------------------------------------
# 2. Kernel A: dbi_rtrim_spaces_len parity (lengths 0..260, unaligned, UTF-8)
# ---------------------------------------------------------------------------
{
    my $mismatches = 0;
    for my $len (0 .. 260) {
        # All spaces
        my $all_sp = ' ' x $len;
        my $g_simd = DBI::_mt_rtrim_spaces($all_sp, 0);
        my $g_scal = DBI::_mt_rtrim_spaces($all_sp, 1);
        $mismatches++ if $g_simd ne $g_scal || $g_simd ne '';

        # No trailing spaces
        my $no_sp = 'a' x $len;
        $g_simd = DBI::_mt_rtrim_spaces($no_sp, 0);
        $g_scal = DBI::_mt_rtrim_spaces($no_sp, 1);
        $mismatches++ if $g_simd ne $g_scal || $g_simd ne $no_sp;

        # Prefix + trailing spaces (varying split)
        my $pfx_len = $len > 0 ? ($len % 37) : 0;
        $pfx_len = $len if $pfx_len > $len;
        my $mixed = ('x' x $pfx_len) . (' ' x ($len - $pfx_len));
        $g_simd = DBI::_mt_rtrim_spaces($mixed, 0);
        $g_scal = DBI::_mt_rtrim_spaces($mixed, 1);
        $mismatches++ if $g_simd ne $g_scal || $g_simd ne ('x' x $pfx_len);
    }
    is($mismatches, 0, 'rtrim_spaces SIMD == scalar across all lengths 0..260 (all-sp/no-sp/mixed)');

    # Non-space whitespace must NOT be trimmed
    my $ws_mismatches = 0;
    for my $ws ("\t", "\n", "\r", "\f", "\x0b", "\x00") {
        for my $tail (0, 1, 15, 16, 17, 31, 32, 33, 64) {
            my $s = ('A' x 20) . $ws . (' ' x $tail);
            my $g_simd = DBI::_mt_rtrim_spaces($s, 0);
            my $g_scal = DBI::_mt_rtrim_spaces($s, 1);
            my $exp    = ('A' x 20) . $ws;
            $ws_mismatches++ if $g_simd ne $g_scal || $g_simd ne $exp;
        }
    }
    is($ws_mismatches, 0, 'rtrim_spaces never trims tabs/newlines/NUL/other whitespace');

    # Unaligned SvOOK offsets 0..31
    my $unalign_mismatches = 0;
    for my $off (0 .. 31) {
        for my $tail (0, 1, 15, 16, 17, 31, 32, 33, 65, 130) {
            my $s = make_unaligned($off, "hello world!" . (' ' x $tail));
            my $g_simd = DBI::_mt_rtrim_spaces($s, 0);
            my $g_scal = DBI::_mt_rtrim_spaces($s, 1);
            $unalign_mismatches++ if $g_simd ne $g_scal || $g_simd ne "hello world!";
        }
    }
    is($unalign_mismatches, 0, 'rtrim_spaces parity across unaligned offsets 0..31');

    # UTF-8 strings (including U+00A0 NBSP which must NOT be trimmed)
    my $utf8_mismatches = 0;
    for my $tail (0, 1, 15, 16, 17, 31, 32, 33, 65) {
        my $base = "caf\x{e9} \x{2603} \x{1F600}\x{00A0}";
        utf8::upgrade($base);
        my $s = $base . (' ' x $tail);
        my $g_simd = DBI::_mt_rtrim_spaces($s, 0);
        my $g_scal = DBI::_mt_rtrim_spaces($s, 1);
        $utf8_mismatches++ if $g_simd ne $g_scal || $g_simd ne $base;
        $utf8_mismatches++ if !utf8::is_utf8($g_simd) || !utf8::is_utf8($g_scal);
    }
    is($utf8_mismatches, 0, 'rtrim_spaces preserves UTF-8 flag and U+00A0 NBSP');
}

# ---------------------------------------------------------------------------
# 3. Kernel B: dbi_scan_sql_plain parity (lengths 0..260, all delims, unaligned)
# ---------------------------------------------------------------------------
{
    my @delims = ("'", '"', '-', '/', '?', ':', '#', "\n", "\r", "\0", '%', '{');
    my $mismatches = 0;

    # Plain strings of every length 0..260 with no delimiter
    for my $len (0 .. 260) {
        my $s = 'A' x $len;
        my $p_simd = DBI::_mt_scan_sql_plain($s, 0);
        my $p_scal = DBI::_mt_scan_sql_plain($s, 1);
        $mismatches++ if $p_simd != $p_scal || $p_simd != $len;
    }
    is($mismatches, 0, 'scan_sql_plain SIMD == scalar for plain strings lengths 0..260');

    # Every delimiter at key boundary positions
    my $delim_mismatches = 0;
    my @positions = (0, 1, 2, 7, 14, 15, 16, 17, 30, 31, 32, 33, 47, 48, 63, 64, 65, 127, 128, 255, 256, 259);
    for my $d (@delims) {
        for my $pos (@positions) {
            my $s = ('S' x $pos) . $d . ('E' x 40);
            my $p_simd = DBI::_mt_scan_sql_plain($s, 0);
            my $p_scal = DBI::_mt_scan_sql_plain($s, 1);
            $delim_mismatches++ if $p_simd != $p_scal || $p_simd != $pos;
        }
    }
    is($delim_mismatches, 0, 'scan_sql_plain SIMD == scalar for all 12 delimiters across chunk boundaries');

    # Unaligned offsets 0..31 + high-bit UTF-8 bytes (must NOT trigger delimiter)
    my $unalign_mismatches = 0;
    for my $off (0 .. 31) {
        my $payload = ("SELECT col_\xc3\xa9 FROM tbl " x 4) . "? AND x = 1";
        my $s = make_unaligned($off, $payload);
        my $p_simd = DBI::_mt_scan_sql_plain($s, 0);
        my $p_scal = DBI::_mt_scan_sql_plain($s, 1);
        $unalign_mismatches++ if $p_simd != $p_scal || $p_simd != index($payload, '?');
    }
    is($unalign_mismatches, 0, 'scan_sql_plain parity across unaligned offsets 0..31 and high-bit bytes');
}

# ---------------------------------------------------------------------------
# 4. Kernel C: dbi_scan_nonprint_or_quote parity (all 256 byte values, neat())
# ---------------------------------------------------------------------------
{
    my $mismatches = 0;
    for my $len (0 .. 260) {
        my $s = 'X' x $len;
        my $p_simd = DBI::_mt_scan_nonprint_or_quote($s, 0);
        my $p_scal = DBI::_mt_scan_nonprint_or_quote($s, 1);
        $mismatches++ if $p_simd != $p_scal || $p_simd != $len;
    }
    is($mismatches, 0, 'scan_nonprint_or_quote SIMD == scalar for printable ASCII lengths 0..260');

    # Exhaustively test all 256 byte values at boundary positions
    my $byte_mismatches = 0;
    for my $b (0 .. 255) {
        my $ch = chr($b);
        my $is_special = ($b < 0x20 || $b >= 0x7f || $ch eq "'" || $ch eq "\\") ? 1 : 0;
        for my $pos (0, 15, 16, 17, 31, 32, 33, 64, 129) {
            my $s = ('a' x $pos) . $ch . ('b' x 35);
            my $exp = $is_special ? $pos : length($s);
            my $p_simd = DBI::_mt_scan_nonprint_or_quote($s, 0);
            my $p_scal = DBI::_mt_scan_nonprint_or_quote($s, 1);
            $byte_mismatches++ if $p_simd != $p_scal || $p_simd != $exp;
        }
    }
    is($byte_mismatches, 0, 'scan_nonprint_or_quote SIMD == scalar for all 256 byte values');

    # Unaligned offsets 0..31
    my $unalign_mismatches = 0;
    for my $off (0 .. 31) {
        my $s = make_unaligned($off, ('A' x 45) . "\x07" . ('B' x 20));
        my $p_simd = DBI::_mt_scan_nonprint_or_quote($s, 0);
        my $p_scal = DBI::_mt_scan_nonprint_or_quote($s, 1);
        $unalign_mismatches++ if $p_simd != $p_scal || $p_simd != 45;
    }
    is($unalign_mismatches, 0, 'scan_nonprint_or_quote parity across unaligned offsets 0..31');

    # End-to-end DBI::neat() verification
    is(DBI::neat("hello world"), "'hello world'", 'neat() plain ASCII');
    is(DBI::neat("ab\x01cd\x7fef"), "'ab.cd.ef'", 'neat() maps control chars and 0x7f to dots');
    is(DBI::neat("it's \\fine"), "'it's \\fine'", 'neat() preserves quotes and backslashes');
    is(DBI::neat("A" x 100, 20), "'" . ("A" x 15) . "...'", 'neat() truncates long strings');
}

# ---------------------------------------------------------------------------
# 5. End-to-end preparse() edge cases (in-process vs PERL_FORCE_SCALAR=1 child)
# ---------------------------------------------------------------------------
{
    my $dbh = DBI->connect('dbi:NullP:', '', '', { RaiseError => 0, PrintError => 0 });
    my @cases = (
        [ "",                                                               DBIpp_ph_qm, DBIpp_ph_cn ],
        [ "SELECT " . ("col_name, " x 30) . "id FROM big_table WHERE a = ? AND b = ?", DBIpp_ph_cn, DBIpp_ph_qm ],
        [ "SELECT * FROM t WHERE x = 'don''t ? touch :1' AND y = ? -- comment ?\nAND z = ?", DBIpp_ph_cn|DBIpp_cm_dd, DBIpp_ph_qm|DBIpp_cm_dd ],
        [ "SELECT /* block ? :1 comment */ a, b FROM t WHERE c = :1 AND d = :2", DBIpp_ph_qm, DBIpp_ph_cn|DBIpp_cm_cs ],
        [ "SELECT a FROM t WHERE pct LIKE '100%' AND id = ? # hash comment\n", DBIpp_ph_sp, DBIpp_ph_qm|DBIpp_cm_hs ],
        [ "SELECT {informix ? comment} col1, col2 FROM t WHERE k = :foo", DBIpp_ph_qm, DBIpp_ph_cs|DBIpp_cm_br ],
        [ "SELECT 'unterminated string with ?", DBIpp_ph_cn, DBIpp_ph_qm ],
        [ "SELECT /* unterminated comment", DBIpp_ph_qm, DBIpp_ph_qm|DBIpp_cm_cs ],
    );

    my @got_local;
    for my $c (@cases) {
        $dbh->set_err(undef, undef);
        my $res = $dbh->preparse($c->[0], $c->[1], $c->[2]);
        push @got_local, [ defined($res) ? $res : '<UNDEF>', $dbh->errstr // '' ];
    }
    $dbh->disconnect;

    # Run identical cases in a PERL_FORCE_SCALAR=1 subprocess and compare bit-for-bit
    local $ENV{PERL_FORCE_SCALAR} = '1';
    my $script = <<'EOS';
use strict; use warnings;
use DBI qw(:preparse_flags);
my $dbh = DBI->connect('dbi:NullP:', '', '', { RaiseError => 0, PrintError => 0 });
my @cases = (
    [ "",                                                               DBIpp_ph_qm, DBIpp_ph_cn ],
    [ "SELECT " . ("col_name, " x 30) . "id FROM big_table WHERE a = ? AND b = ?", DBIpp_ph_cn, DBIpp_ph_qm ],
    [ "SELECT * FROM t WHERE x = 'don''t ? touch :1' AND y = ? -- comment ?\nAND z = ?", DBIpp_ph_cn|DBIpp_cm_dd, DBIpp_ph_qm|DBIpp_cm_dd ],
    [ "SELECT /* block ? :1 comment */ a, b FROM t WHERE c = :1 AND d = :2", DBIpp_ph_qm, DBIpp_ph_cn|DBIpp_cm_cs ],
    [ "SELECT a FROM t WHERE pct LIKE '100%' AND id = ? # hash comment\n", DBIpp_ph_sp, DBIpp_ph_qm|DBIpp_cm_hs ],
    [ "SELECT {informix ? comment} col1, col2 FROM t WHERE k = :foo", DBIpp_ph_qm, DBIpp_ph_cs|DBIpp_cm_br ],
    [ "SELECT 'unterminated string with ?", DBIpp_ph_cn, DBIpp_ph_qm ],
    [ "SELECT /* unterminated comment", DBIpp_ph_qm, DBIpp_ph_qm|DBIpp_cm_cs ],
);
for my $c (@cases) {
    $dbh->set_err(undef, undef);
    my $res = $dbh->preparse($c->[0], $c->[1], $c->[2]);
    my $r = defined($res) ? $res : '<UNDEF>';
    my $e = $dbh->errstr // '';
    print unpack('H*', $r), '|', unpack('H*', $e), "\n";
}
$dbh->disconnect;
EOS
    open my $fh, '-|', $^X, @inc_flags, '-e', $script or die "spawn failed: $!";
    my @child_lines = <$fh>;
    close $fh;
    chomp @child_lines;

    is(scalar(@child_lines), scalar(@got_local), 'preparse scalar child returned all cases');
    for my $i (0 .. $#got_local) {
        my ($r_hex, $e_hex) = split /\|/, $child_lines[$i], 2;
        my $c_res = pack('H*', $r_hex);
        my $c_err = pack('H*', $e_hex);
        is($got_local[$i][0], $c_res, "preparse case $i result matches PERL_FORCE_SCALAR=1 bit-for-bit");
        is($got_local[$i][1], $c_err, "preparse case $i errstr matches PERL_FORCE_SCALAR=1 bit-for-bit");
    }
}

# ---------------------------------------------------------------------------
# 6. End-to-end ChopBlanks via DBD::Sponge / _set_fbav()
# ---------------------------------------------------------------------------
{
    my $dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1 });
    my $utf8_val = "caf\x{e9}\x{00A0}";
    utf8::upgrade($utf8_val);

    my @rows = (
        [ "short   ", "exact", "   ", "", undef, 42 ],
        [ "x" . (" " x 64), "y" . (" " x 135), "tab\t   ", $utf8_val . (" " x 40), "nl\n  ", " " x 200 ],
    );

    # ChopBlanks => 0 preserves spaces
    my $sth0 = $dbh->prepare('cb0', {
        NAME => [qw(c1 c2 c3 c4 c5 c6)],
        rows => [ map { [ @$_ ] } @rows ],
    });
    $sth0->{ChopBlanks} = 0;
    $sth0->execute;
    my $r0 = $sth0->fetchrow_arrayref;
    is($r0->[0], "short   ", 'ChopBlanks=0 preserves trailing spaces');
    $sth0->finish;

    # ChopBlanks => 1 trims trailing ASCII spaces via SIMD/scalar kernel
    my $sth1 = $dbh->prepare('cb1', {
        NAME => [qw(c1 c2 c3 c4 c5 c6)],
        rows => [ map { [ @$_ ] } @rows ],
    });
    $sth1->{ChopBlanks} = 1;
    $sth1->execute;
    my $got1 = [ @{ $sth1->fetchrow_arrayref } ];
    my $got2 = [ @{ $sth1->fetchrow_arrayref } ];
    $sth1->finish;
    $dbh->disconnect;

    is_deeply($got1, [ "short", "exact", "", "", undef, 42 ],
        'ChopBlanks=1 trims short/all-space/empty and preserves undef & numbers');
    is_deeply($got2, [ "x", "y", "tab\t", $utf8_val, "nl\n", "" ],
        'ChopBlanks=1 trims 64B/135B/200B/UTF-8 trailing spaces and preserves tab/nl/NBSP');
    ok(utf8::is_utf8($got2->[3]), 'ChopBlanks=1 preserves UTF-8 flag on trimmed SV');
}

# ---------------------------------------------------------------------------
# 7. Multi-worker concurrency (MT::Image::freeze + 4 concurrent workers)
# ---------------------------------------------------------------------------
if ($has_mt) {
    sub arch_worker {
        my ($wid) = @_;
        my $wi = DBI::mt_arch_info();
        my $errs = 0;

        my $dbh = DBI->connect('dbi:Sponge:', '', '', { RaiseError => 1 });
        for my $iter (1 .. 40) {
            my $len = ($wid * 17 + $iter * 5) % 256;
            my $sp  = "w${wid}_${iter}_" . (' ' x $len);
            my $r_s = DBI::_mt_rtrim_spaces($sp, 0);
            my $r_c = DBI::_mt_rtrim_spaces($sp, 1);
            $errs++ if $r_s ne $r_c;

            my $sql = "SELECT " . ("col$wid, " x 12) . "val FROM t$wid WHERE id = ? AND k = :1";
            my $q_s = DBI::_mt_scan_sql_plain($sql, 0);
            my $q_c = DBI::_mt_scan_sql_plain($sql, 1);
            $errs++ if $q_s != $q_c;

            my $np = ('A' x ($len % 90)) . "\x02tail";
            my $n_s = DBI::_mt_scan_nonprint_or_quote($np, 0);
            my $n_c = DBI::_mt_scan_nonprint_or_quote($np, 1);
            $errs++ if $n_s != $n_c;

            my $pp = $dbh->preparse($sql, DBIpp_ph_cn, DBIpp_ph_qm);
            $errs++ if !defined($pp) || $pp !~ /:p1/;

            my $sth = $dbh->prepare("w_${wid}_${iter}", {
                NAME => ['a', 'b'],
                rows => [ [ $sp, "ok" . (' ' x ($iter % 35)) ] ],
            });
            $sth->{ChopBlanks} = 1;
            $sth->execute;
            my $row = $sth->fetchrow_arrayref;
            $errs++ if $row->[0] ne "w${wid}_${iter}_" || $row->[1] ne "ok";
            $sth->finish;
        }
        $dbh->disconnect;
        return join('|', $wi->{arch}, $wi->{simd}, $wi->{cacheline}, $errs);
    }

    eval { MT::Image::freeze(); 1 }
        or fail("MT::Image::freeze() died: $@");
    pass('MT::Image::freeze() succeeded with arch/SIMD DBI loaded');

    my @workers = map { MT::Worker::spawn('main::arch_worker', $_) } 1 .. 4;
    for my $i (0 .. $#workers) {
        my $wid = $i + 1;
        my $res = MT::Worker::join($workers[$i]);
        my ($w_arch, $w_simd, $w_cl, $w_errs) = split /\|/, $res, 4;
        is($w_arch, $info->{arch},      "worker $wid reports arch=$info->{arch}");
        is($w_simd, $info->{simd},      "worker $wid reports simd=$info->{simd}");
        is($w_cl,   $info->{cacheline}, "worker $wid reports cacheline=$info->{cacheline}");
        is($w_errs, 0,                  "worker $wid had 0 parity/concurrency errors");
    }
}

# ---------------------------------------------------------------------------
# 8. Micro-benchmark (diagnostic output)
# ---------------------------------------------------------------------------
{
    my $iters = 5_000;
    my $rtrim_in = "payload" . (' ' x 1024);
    my $sql_in   = ("SELECT col_alpha, col_beta, col_gamma FROM some_table_name WHERE status = 1 AND " x 12) . "id = ?";
    my $np_in    = ('A' x 1020) . "\x01xyz";

    my $bench = sub {
        my ($label, $sub_simd, $sub_scal, $bytes) = @_;
        my $t0 = time();
        $sub_simd->() for 1 .. $iters;
        my $dt_simd = time() - $t0;
        $dt_simd = 1e-6 if $dt_simd <= 0;

        my $t1 = time();
        $sub_scal->() for 1 .. $iters;
        my $dt_scal = time() - $t1;
        $dt_scal = 1e-6 if $dt_scal <= 0;

        my $mb_simd = ($iters * $bytes / (1024 * 1024)) / $dt_simd;
        my $mb_scal = ($iters * $bytes / (1024 * 1024)) / $dt_scal;
        my $speedup = $dt_scal / $dt_simd;
        diag(sprintf(
            "bench %-24s [%s/%s CL=%d]: simd=%.1f MB/s scalar=%.1f MB/s (%.2fx)",
            $label, $info->{arch}, $info->{simd}, $info->{cacheline},
            $mb_simd, $mb_scal, $speedup
        ));
    };

    $bench->('rtrim_spaces(1KiB)',
        sub { DBI::_mt_rtrim_spaces($rtrim_in, 0) },
        sub { DBI::_mt_rtrim_spaces($rtrim_in, 1) },
        length($rtrim_in));

    $bench->('scan_sql_plain(1KiB)',
        sub { DBI::_mt_scan_sql_plain($sql_in, 0) },
        sub { DBI::_mt_scan_sql_plain($sql_in, 1) },
        length($sql_in));

    $bench->('scan_nonprint(1KiB)',
        sub { DBI::_mt_scan_nonprint_or_quote($np_in, 0) },
        sub { DBI::_mt_scan_nonprint_or_quote($np_in, 1) },
        length($np_in));
}

done_testing();
