#!/usr/bin/perl

use strict;

use utf8;
use open ':encoding(utf8)';

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

use Net::Twitter;
use Data::Dumper;

my $base_path = '.';

sub format_value
{
    my $v = shift;
    (my $iv = int $v) =~ s/(\d)(?=(\d{3})+(\D|$))/$1\./g;
    my $fv = (int $v*100)%100;
    return sprintf("%s,%02d", $iv, $fv);
}

sub make_message_normal
{
    open my $data, "$base_path/filtered";

    my @data;

    while (my $line = <$data>) {
        chomp $line;
        my ($date, $from, $to, $value) = split /\t/, $line;
        push @data, { date => $date, from => $from, to => $to, value => $value };
    }

    my $data = $data[int rand scalar @data];
    my $fv = format_value($data->{value});

    return "$data->{from} pagou R\$ $fv para $data->{to} em $data->{date}\n";
}

sub make_message_contracheque
{
    my @sources = qw(contracheque-top contracheque-top contracheque-topzera);
    my $source = $sources[int rand scalar @sources];

    open my $data, "$base_path/$source";

    my @data;

    while (my $line = <$data>) {
        chomp $line;
        my ($name, $cargo, $value, $when) = split /\t/, $line;
        push @data, { name => $name, cargo => $cargo, value => $value, when => $when };
    }

    my $data = $data[int rand scalar @data];
    my $fv = format_value($data->{value});

    (my $cargo = $data->{cargo}) =~ s/ +/ /g;

    my $name = $data->{name};

    $name =~ s/\bD[AOE]S? //g;
    $name =~ s/ (\S)\S*/ \1./g;
    $name =~ s/ +/ /g;

    # $name =~ s/^(\S*) .*\b(\S).*/\1 \2./;

    return "Total de créditos de $name ($cargo) em $data->{when}: R\$ $fv";
}

# achou que eu ia deixar isso publico?
my $consumer_key = 'x';
my $consumer_secret = 'x';
my $access_token = 'x';
my $access_token_secret = 'x';

my $nt = Net::Twitter->new(
      traits   => [qw/API::RESTv1_1/],
      consumer_key        => $consumer_key,
      consumer_secret     => $consumer_secret,
      access_token        => $access_token,
      access_token_secret => $access_token_secret,
);

for (1 .. 3) {
    my $msg;

    do {
        $msg = make_message_contracheque();
    } while (length($msg) > 138);

    eval { $nt->update($msg); };
    last if !$@;
}
