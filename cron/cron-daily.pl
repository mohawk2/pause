#!/usr/bin/perl

my $Id = q$Id: cron-daily.pl,v 1.31 2002/04/29 09:41:52 k Exp k $;

use lib "/home/k/PAUSE/lib";
use PAUSE ();

use File::Basename ();
use DBI;
use Mail::Send ();
use File::Find ();
use FileHandle ();
use File::Copy ();
use HTML::Entities ();
use IO::File ();
use strict;
use vars qw( $last_str $last_time $SUBJECT @listing $Dbh);

#
# Initialize
#

my $now = time;
my @TIME = localtime($now);
$TIME[4]++;
$TIME[5]+=1900;
my $TIME = sprintf "%02d" x 5, @TIME[5,4,3,2,1];

my $zcat = "/bin/zcat";
die "no executable zcat" unless -x $zcat;
my $gzip = "/bin/gzip";
die "no executable gzip" unless -x $gzip;

sub report;
report "Running $Id\n";

my(@blurb, %fields);
unless ($Dbh = DBI->connect(
			   $PAUSE::Config->{MOD_DATA_SOURCE_NAME},
			   $PAUSE::Config->{MOD_DATA_SOURCE_USER},
			   $PAUSE::Config->{MOD_DATA_SOURCE_PW},
			   { RaiseError => 1 }
			  )) {
  report "Connect to database not possible: $DBI::errstr\n";
}

# read_errorlog();
for_authors();
watch_files();
delete_scheduled_files();
send_the_mail();

exit;

#
# Read the errorlog
#

sub read_errorlog {
  if (open LOG, $PAUSE::Config->{HTTP_ERRORLOG}) {
    my($errorlines);
    while (<LOG>) {
	$errorlines++;
	next unless /failed/;
	report $_;
    }
    close LOG;
    report "\nErrorlog contains $errorlines lines today\n";
  } else {
    warn "error opening $PAUSE::Config->{HTTP_ERRORLOG}: $!";
  }
}

#
# Write the 00whois.html file
#

sub for_authors {
  my($error);
  if ($error = whois()){
    report $error;
  } elsif (system('/usr/local/bin/cmp',
		  '-s',
		  '00whois.new',
		  "$PAUSE::Config->{MLROOT}/../00whois.html"
		 )!=0) {
    report qq{Running: /bin/cp 00whois.new $PAUSE::Config->{MLROOT}/../00whois.html\n\n};
    system('/bin/cp',
	   '00whois.new',
	   "$PAUSE::Config->{MLROOT}/../00whois.html");
  }
  if ($error = mailrc()) {
    report $error;
  }
  my $current_excuse = "";
  my $excuse_file = "$PAUSE::Config->{FTPPUB}/authors/00.Directory.Is.Not.Maintained.Anymore";
  if (-f $excuse_file) {
    open FH, $excuse_file or die;
    local $/;
    $current_excuse = <FH>;
    close FH;
  }

  my $my_excuse = "  ".

qq{The symbolic links to the long usernames in this directory are an
historic accident. Please do not use them, look into

  CPAN/authors/00whois.html

or if you prefer

  CPAN/authors/01mailrc.txt.gz

instead.

Long story: When CPAN turned out to be more of a success than expected
it had to be adjusted to permit more or less unlimited growth. An
appendage from that time is this directory. Biggest stupidity was to
allow 8bit characters in directory names without thinking about
character sets. Second biggest mistake was to fill up a single
directory with hundreds of entries. Now, they cannot be removed
because lots of people have made links to individual entries here. But
it's stupid to continue to maintain them because every click on this
directory entry costs a lot of time and with more authors it will
become more expensive to click on the directory listing. So please do
not rely on the contents of this directory

 *** except for the subdirectory "id". ***

Ignore everything else, expect it to go away in the future.

Thank you,
Your CPAN team
};
  if ($current_excuse ne $my_excuse) {
    open FH, ">$excuse_file" or die;
    print FH $my_excuse;
    close FH;
  }
}

sub ls {
    my($name) = @_;
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$sizemm,
     $atime,$mtime,$ctime,$blksize,$blocks) = lstat($name);

    my($perms,%user,%group);
    my $pname = $name;

    if (defined $blocks) {
	$blocks = int(($blocks + 1) / 2);
    }
    else {
	$blocks = int(($sizemm + 1023) / 1024);
    }

    if    (-f _) { $perms = '-'; }
    elsif (-d _) { $perms = 'd'; }
    elsif (-c _) { $perms = 'c'; $sizemm = &sizemm; }
    elsif (-b _) { $perms = 'b'; $sizemm = &sizemm; }
    elsif (-p _) { $perms = 'p'; }
    elsif (-S _) { $perms = 's'; }
    else         { $perms = 'l'; $pname .= ' -> ' . readlink($_); }

    my(@rwx) = ('---','--x','-w-','-wx','r--','r-x','rw-','rwx');
    my(@moname) = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my $tmpmode = $mode;
    my $tmp = $rwx[$tmpmode & 7];
    $tmpmode >>= 3;
    $tmp = $rwx[$tmpmode & 7] . $tmp;
    $tmpmode >>= 3;
    $tmp = $rwx[$tmpmode & 7] . $tmp;
    substr($tmp,2,1) =~ tr/-x/Ss/ if -u _;
    substr($tmp,5,1) =~ tr/-x/Ss/ if -g _;
    substr($tmp,8,1) =~ tr/-x/Tt/ if -k _;
    $perms .= $tmp;

    my $user = $user{$uid} || $uid;   # too lazy to implement lookup
    my $group = $group{$gid} || $gid;

    my($sec,$min,$hour,$mday,$mon,$year) = localtime($mtime);
    my($timeyear);
    my($moname) = $moname[$mon];
    if (-M _ > 365.25 / 2) {
	$timeyear = $year + 1900;
    }
    else {
	$timeyear = sprintf("%02d:%02d", $hour, $min);
    }

    sprintf "%5lu %4ld %-10s %2d %-8s %-8s %8s %s %2d %5s %s\n",
	    $ino,
		 $blocks,
		      $perms,
			    $nlink,
				$user,
				     $group,
					  $sizemm,
					      $moname,
						 $mday,
						     $timeyear,
							 $pname;
}

#
# Report about young files, old files and backups
#

sub watch_files {
    report "\nYoungsters\n----------\n";
    @listing = (); #global variable
    File::Find::find(
		     sub {
			 stat;
			 -f _ or return;
			 -M _ > 2 && return;
			 push(@listing,
			      sprintf "%-60s %8d %6.2f\n",
			      substr($File::Find::name,
				     length($PAUSE::Config->{MLROOT})
				    ),
			      -s _,
			      -M _
			     );
		       }, $PAUSE::Config->{MLROOT});
    report(map { $_->[0] }
	   sort {$a->[1] <=> $b->[1]}
	   map { my $mod; (undef,undef,$mod) = split; [ $_, $mod ] }
	   @listing
	  );


    report "\nDelete candidates\n-----------------\n";
    @listing = (); #global variable
    mkdir qq{$PAUSE::Config->{INCOMING_LOC}/old}, 0755
	unless -d qq{$PAUSE::Config->{INCOMING_LOC}/old};
    File::Find::find(
		     sub {
			 stat;
			 return if /^\.message/;
			 if (-f _) {
			   # ROGER
			 } elsif (-d _) {
			   return if $_ eq "old" || $_ eq "." || $_ eq "..";
			   # all other directories are forbidden
			   require Dumpvalue;
			   my $d = Dumpvalue->new(
						  tick => "\"",
						  printUndef => "uuuuu",
						  unctrl => "unctrl",
						  quoteHighBit=>1,
						 );
			   my $v = $d->stringify($File::Find::name);
			   warn sprintf qq{Found a bad directory v[%s], rmtree-ing}, $v;
			   require File::Path;
			   File::Path::rmtree($File::Find::name);
			 }
			 if (-M _ > 2) {
			   if (rename($_,"old/$_")) {
			     # nothing to do
			   } elsif (-M _ > 20) {
			     unlink($_);
			   }
			   return;
			 }
			 push(
			      @listing,
			      sprintf "%-60s %8d %6.2f\n",
			      $File::Find::name,
			      -s _,
			      -M _
			     );
		     }, $PAUSE::Config->{INCOMING_LOC});
    report sort {substr($a,70) <=> substr($b,70)} @listing;
    File::Find::find(
		     sub {
			 stat;
			 -f _ or return;
			 -M _ > 35 && unlink($_) && return;
		     }, $PAUSE::Config->{PAUSE_PUBLIC_DATA});

    report "\nIn $PAUSE::Config->{TMP}\n--------------------\n";
    @listing = (); #global variable
    File::Find::finddepth(
			  sub {
			      stat;
			      -d _ and rmdir $_; # won't succeed if non-empty
			      -f _ or return;
			      -M _ > 4 && unlink($_) && return;
			      push(
				   @listing,
				   sprintf("%-60s %8d %6.2f\n",
					   $File::Find::name,
					   -s _,
					   -M _
					  )
				  );
			  }, $PAUSE::Config->{TMP});

    report sort {substr($a,70) <=> substr($b,70)} @listing;
}

#
# delete files being scheduled for deletion
#

sub delete_scheduled_files {
    my $sth = $Dbh->prepare("SELECT deleteid, changed FROM deletes");
    $sth->execute;
    %fields = ();
    report "\n\nDeleting files scheduled for deletion\n";
    while (@fields{'deleteid','changed'} = $sth->fetchrow_array) {
      my $d = $fields{deleteid};
      my $delete = "$PAUSE::Config->{MLROOT}$d";
      report "Scheduled is: $d\n";
      next if $now - $fields{changed} < ($PAUSE::Config->{DELETES_EXPIRE}
					 || 60*60*24*2);
      report "    Deleting $delete\n";
      unlink $delete;
      $Dbh->do("DELETE FROM deletes WHERE deleteid='$d'");
      next if $d =~ /\.readme$/;
      my $readme = $delete;
      $readme =~ s/(\.tar.gz|\.zip)$/.readme/;
      if (-f $readme) {
	report "     Deletin $readme\n";
	unlink $readme;
      }
    }
}



#
# Send the mail end leave me alone
#

sub send_the_mail {
    $SUBJECT ||= "cron-daily.pl";
    my $MSG = Mail::Send->new(
			      Subject => $SUBJECT,
			      To=>$PAUSE::Config->{ADMIN}
			     );
    $MSG->add(
	      "From",
	      "cron daemon cron-daily.pl <upload>"
	     );
    my $FH  = $MSG->open('sendmail');
    print $FH join "", @blurb;
    $FH->close;
}

sub do_log {
    my($arg) = @_;
    my $stamp = &timestamp."-$$: ";
    my $from = join ":", caller;
# open the log file
    my $logfile = "$PAUSE::Config->{PAUSE_LOG_DIR}/cron-daily.log";
    local *LOG;
    open LOG, ">>$logfile" or die "open $logfile: $!";
# LOG->autoflush;

    print LOG $stamp, $arg, " ($from)\n";
    close LOG;
}

sub timestamp { # Efficiently generate a time stamp for log files
    my $time = time;	# optimise for many calls in same second
    return $last_str if $last_time and $time == $last_time;
    my($sec,$min,$hour,$mday,$mon,$year)
	= localtime($last_time = $time);
    $last_str = sprintf("%02d%02d%02d %02u:%02u:%02u",
		    $year,$mon+1,$mday, $hour,$min,$sec);
}

sub whois {
    my(@row);
    my $stu = $Dbh->prepare("SELECT userid, fullname, email,
	isa_list, homepage, asciiname FROM users ORDER BY fullname");
    $stu->execute;
    open FH, ">00whois.new" or return "Error: Can't open 00whois.new: $!";
    my $now = gmtime;
    print FH qq{<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "DTD/xhtml1-transitional.dtd"><html><!-- -*- coding: utf-8 -*- --><head>
<title>who is who on the perl module list</title></head>
<body>
	<h3>People, <a href="#mailinglists">Mailinglists</a> And
	<a href="#mlarchives">Mailinglist Archives</a> </h3>
<i>generated on $now GMT by $PAUSE::Config->{ADMIN}</i>
<pre xml:space="preserve">
};

    while (@row = $stu->fetchrow_array) {
	my $address;
#0=userid, 1=fullname, 2=email, 3=isa_list, 4=homepage, 5=asciiname
	my $name = $row[0];
        ##### 
	$name =~ s/\s//g;
	if ($row[3]) {
	    # printf FH "  <A NAME=\"%s\"></A>%-10s%s\n", $name, $row[0], qq{<A HREF="#mailinglists">See below</A>};
	} else {
	    my @address;
	    # address[0]: directory

	    my $userhome = PAUSE::user2dir($row[0]);

	    my $fill = " " x (9 - length($row[0]));
	    $address[0] = -d "$PAUSE::Config->{MLROOT}/$userhome" ?
		qq{<a href="id/$userhome/">$row[0]</a>$fill} : "$row[0]$fill";

	    # address[1]: fullname link to homepage

            # When we decided to produce xhtml, we had to entitify
            # latin1 and could let through utf-8

            # we must encode with HTML::Entities only latin1 bytes, not UTF-8;

            my $xfullname = escapeHTML($row[5] ? "$row[1] (=$row[5])" : $row[1]);
	    $address[1] = $row[4] ?
		sprintf(
                        qq{<a href="%s">%s</a>},
                        escapeHTML($row[4]),
                        $xfullname,
                       ) : $xfullname;

	    # address[2]: mailto
	    # $address[2] = qq{<a href="mailto:$row[2]">&lt;$row[2]&gt;</a>};
	    # now without mailto
	    $address[2] = qq{&lt;$row[2]&gt;};
	    print FH qq{<a id="$name" name="$name"></a>}, join(" ", @address), "\n";
	}
    }

    my $stm = $Dbh->prepare("SELECT maillistid, maillistname,
		address, subscribe FROM maillists ORDER BY maillistid");
    $stm->execute;
    print FH q{
</pre>
<h3><a id="mailinglists" name="mailinglists">Mailing Lists</a></h3>
<dl>
};

    while (@row = $stm->fetchrow_array){
	print FH qq{<dt><a id="$row[0]" name="$row[0]">$row[0]</a></dt><dd>$row[1]};
	print FH " &lt;$row[2]&gt;" if $row[2];
	print FH "<br />";
	my $subscribe = $row[3];
	$subscribe =~ s/\s+/ /gs;
	HTML::Entities::encode($subscribe);
	print FH $subscribe, "<p> </p></dd>\n";
    }

    print FH q{
	</dl>
    };

    my $query = "SELECT mlaid, comment FROM mlas ORDER BY mlaid";
    $stm = $Dbh->prepare($query);
    $stm->execute;
    print FH q{
	<h3><a id="mlarchives" name="mlarchives">Mailing List Archives</a></h3><dl>
    };
    my($hash);
    while ($hash = $stm->fetchrow_hashref) {
	for (keys %$hash) {
	    HTML::Entities::encode($hash->{$_},'<>&');
	}
	print FH qq{
	    <dt><a href="$hash->{mlaid}"
                        >$hash->{mlaid}</a></dt><dd
                        >$hash->{comment}<p> </p></dd>
	};
    }
    print FH q{
        </dl></body></html>
    };
    close FH;
    return;
}

sub mailrc {
    #
    # Rewriting 01mailrc.txt
    #

    my $repfile = "$PAUSE::Config->{MLROOT}/../01mailrc.txt.gz";
    my $list = "";
    my $olist = "";
    local($/) = undef;
    if (open F, "$zcat $repfile|") {
	$olist = <F>;
	close F;
    }
    my $stu = $Dbh->prepare("SELECT userid, fullname, email, asciiname
                             FROM users
                             WHERE isa_list=''
                             ORDER BY userid");
    $stu->execute;
    my(@r);
    while (@r = $stu->fetchrow_array){
      $r[2] ||= sprintf q{%s@cpan.org}, lc($r[0]);
      my $state = 0;
      $r[1] = $r[3] if $r[3];
      while ( $r[1] =~ m/\"/g) {
        $state ^= 1;
        $state ? $r[1] =~ s/\"/\'/ : $r[1] =~ s/\"/\'/;
      }
      $list .= sprintf qq{alias %-10s "%s <%s>"\n}, @r[0..2];
    }
    $stu = $Dbh->prepare("SELECT maillistid, maillistname, address
                          FROM maillists");
    $stu->execute;
    while (@r = $stu->fetchrow_array){
	next unless $r[2];
	$list .= sprintf qq{alias %-6s "%s <%s>"\n}, @r[0..2];
    }
    if ($list ne $olist) {
	if (open F, "| $gzip -9c > $repfile") {
	    print F $list;
	    close F;
	} else {
	    return("ERROR: Couldn't open 01mailrc...");
	}
    } else {
#	print "Endlich keine neue Version geschrieben\n";
    }
    return;
}

sub report {
    my(@rep) = @_;
    push @blurb, @rep;
}

sub escapeHTML {
  my($what) = @_;
  return unless defined $what;
  # require Devel::Peek; Devel::Peek::Dump($what) if $what =~ /Andreas/;
  my %escapes = qw(& &amp; " &quot; > &gt; < &lt;);
  $what =~ s[ ([&"<>]) ][$escapes{$1}]xg; # ]] cperl-mode comment
  $what;
}
