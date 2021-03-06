#!/usr/bin/perl

=pod

remove everything from distmtimes that prevents mldistwatch from indexing.

I'm using it to study the outcome of the new version-enhanced mldistwatch.

=cut

use strict;
use warnings;

use lib "lib", "privatelib";
use PAUSE;
use Parse::CPAN::Packages;

my $dbh = PAUSE::dbh;
my $sth = $dbh->prepare("delete from distmtimes where dist=?");
my $p = Parse::CPAN::Packages->
    new("/home/ftp/pub/PAUSE/modules/02packages.details.txt-20051208.gz") or die;
$| = 1;
my $i;
for my $d ($p->latest_distributions){
  my $prefix = $d->prefix;
  # warn "sharpening prefix[$prefix]\n";
  print "." unless ++$i % 32;
  $sth->execute($prefix);
}
print "\n";
