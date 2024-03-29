=head1 NAME

Rcs::Parser - Parse and analyze RCS files.

=head1 SYNOPSIS

A basic RCS parser. This file does not rely upon any external utilities to
parse RCS files. Currently it functions with RCS files generated by GNU 
CVS and as documented by the rcsfile(5) man page. 

=head1 EXAMPLE USAGE

Retrieve the most recent file from an archive:

  my $rcs = new Rcs::Parser;
  my $ret = $rcs->load($filename);
  
  my $current = $rcs->recent_version;

To retrieve a specific version:

  my $rcs = new Rcs::Parser;
  my $ret = $rcs->load($filename);
  
  my $specific_version = $rcs->get('1.2');

=cut

# shorthand document of memory structure
#
# - version
# - body
#   - line #
#     - line
#     - origin
#     - new_lines
# - line_map

#*************************************************************************

package Rcs::Parser;
$Rcs::Parser::VERSION = '0.08';

use 5.006001;
use Sort::Versions;
use warnings;
use strict;

sub new {
  bless {}, $_[0]
}

=head1 METHODS:

=head2 author($version)

my $author = $rcs->author($version);

The author method returns the author name of the given version. If
no version is given it returns the author of the current loaded version.

=cut 

sub author {
  my $self = shift @_;
  my $ver  = shift @_ || $self->version;
  return $self->{rcs}->{$ver}->{author} || undef;
}

=head2 date($version)

my $date = $rcs->date($version);

The date method returns the revision date of the given version. If
no version is given it returns the date of the current version.

=cut

sub date {
  my $self = shift @_;
  my $ver  = shift @_ || $self->recent_version;
  return $self->{rcs}->{$ver}->{date} || undef;
}

=head2 get($version)

my $ret = $rcs->get($version);

This method causes the given version to be retrieved from the archive

=cut

sub get {
  my $self = shift @_;
  my $ver  = shift @_ || $self->recent_version;
  
  return undef unless $self->{rcs}->{$ver};

  my @chain = $self->_revision_path($self->{current_document}->{version},$ver);

  for my $version ( @chain ) {
    $self->_debug("--> loading delta $version");
    $self->_apply_delta($version);
    $self->_sort;
  }

  return $self->_dump;
}

=head2 load($filename)

my $ret = $rcs->load($filename);

The load command reads in and parses the given filename. If the
file does not exist or is unreadable by the script, undef is 
returned. Otherwise, 1 is returned upon success.

=cut

sub load {
  my $self      = shift @_;
  $self->{file} = shift @_;
  return undef unless -f $self->{file};

  my $doc_header;
  $self->{rcs} = {};

  open RCSFILE, '<', $self->{file};
  $self->{rawfile} = join('',<RCSFILE>);
  close RCSFILE;

  $self->_parse_in_rcs($self->{rcs});

  # populate the current doc
  
  $self->{current_document}->{version} = $self->recent_version;

  for my $line ( split /\n/, $self->{rcs}->{$self->recent_version}->{text} ) {
    push @{ $self->{current_document}->{body}->{1}->{new_lines} }, $self->_unquote($line) . "\n";
  }

  # resort it

  $self->_sort;

  return 1;
}

=head2 load_scalar($data)

my $ret = $rcs->load_scalar($data);

The load command reads in and parses the provided RCS file in scalar 
form. 1 is returned upon success.

=cut

sub load_scalar {
  my $self  = shift @_;
  my $data  = shift @_;

  my $doc_header;
  $self->{rcs} = {};

  my @raw = map { "$_\n" } split "\n", $data;

  $self->{rawfile} = \@raw; # The rawfile is steadily deleted as it is parsed
  $self->_parse_in_rcs($self->{rcs});

  # populate the current doc
  
  $self->{current_document}->{version} = $self->recent_version;

  for my $line ( split /\n/, $self->{rcs}->{$self->recent_version}->{text} ) {
    push @{ $self->{current_document}->{body}->{1}->{new_lines} }, $self->_unquote($line) . "\n";
  }

  # resort it

  $self->_sort;

  return 1;
}

=head2 notate()

my $ret = $rcs->notate()

This method builds and assembled statistical information for verions.

=cut

sub notate {
  my $self = shift @_;
  my $ver  = $self->recent_version;

  my $note = {};
  
  return undef unless $self->{rcs}->{$ver};

  $self->_grab_note($note);

  
  my @chain = $self->_revision_path($self->{current_document}->{version});

  for my $version ( @chain ) {
    $self->_debug("--> loading delta $version");
    $self->_apply_delta($version);
    $self->_sort;
    $self->_grab_note($note);
  }

  for my $version ( reverse @chain, $self->recent_version ) {
    if ( $version eq $chain[$#chain] ) {
      $self->_debug("Mapping $version pro facia ...");
      map { $note->{$version}->{body}->{$_}->{origin} = $version; } keys %{$note->{$version}->{body}};
    } else {
      $self->_debug("Mapping $version via line count ...");
      my $error;
      for my $line ( keys %{$note->{$version}->{body}} ) {
        
        my $author_ver = $version;
        my $test_line  = $line;
        my $test_ver   = $self->previous_version($version);
        
        $error++ unless defined $test_ver;
        
        while ( $note->{$test_ver}->{line_map}->{$test_line} ) {
          $author_ver = $test_ver;
          $test_line  = $note->{$test_ver}->{line_map}->{$test_line};
          $test_ver   = $self->previous_version($author_ver) || last; #??? break if we bottom on version?
        } 
      
        $note->{$version}->{body}->{$line}->{origin} = $author_ver;
      }
      warn "WARN: $error lines didn't map well for $self->{file} $version"
            if $error > 0;
    }
  }

  return $note;
}

sub _grab_note {
  my $self = shift @_;
  my $ref  = shift @_;  
  my $ver = $self->{current_document}->{version};
  for my $line ( keys %{ $self->{current_document}->{body} } ) {
    $ref->{$ver}->{body}->{$line}->{line}   = length $self->{current_document}->{body}->{$line}->{line};
    $ref->{$ver}->{body}->{$line}->{origin} = $self->{current_document}->{body}->{$line}->{origin};  
  }
  for my $map ( keys %{ $self->{current_document}->{line_map} } ) {
    $ref->{$ver}->{line_map}->{$map} = $self->{current_document}->{line_map}->{$map};
  }

  return 1;
}

=head2 all_versions()

my @versions = $rcs->all_versions();

This method returns an array or arrayref of all versions stored in the RCS file.

=cut

sub all_versions {
  my $self = shift @_;
  unless ( defined $self->{all_versions} ) {
    $self->{all_versions} = [ sort { versioncmp($b,$a) } grep !/(header|desc)/, keys %{$self->{rcs}} ];
  }
  return wantarray ? @{$self->{all_versions}} : $self->{all_versions};
}

=head2 previous_version()

my $ver = $rcs->previous_version();

This method returns the version previous to the currently instanced version.

=cut

sub previous_version {
  my $self = shift @_;
  my $ver  = shift @_ || $self->recent_version;
  return $self->{rcs}->{revision_path}->{$ver};
}

=head2 recent_version()

my $ver = $rcs->recent_version();

This method returns the most current revision of the file.

=cut

sub recent_version {
  my $self = shift @_;
  return $self->{rcs}->{header}->{head};
}

=head2 version()

my $ver = $rcs->version();

This method returns the currently instanced version.

=cut

sub version {
  my $self = shift @_;
  return $self->{current_document}->{version};
}

#### Private methods

sub _apply_delta {
  my $self = shift @_;
  my $ver  = shift @_;
  my $doc  = shift @_ || $self->{current_document};

  my $raw_delta = $self->{rcs}->{$ver}->{text};
  $doc->{version} = $ver;

  my @deltas = split /\n/, $raw_delta;

  while ( @deltas ) {
    my $delta = shift @deltas;
    if ( $delta =~ /^a(\d+) (\d+)$/ ) { 
      my $line  = $1;
      my $count = $2;
      my $test  = 0;
      
      for ( my $c = 0; $c < $count; $c++ ) {
        my $new_line = $self->_unquote( shift @deltas ) . "\n";
        push @{ $doc->{body}->{$line}->{new_lines} }, $new_line;
        $test++;
      }
      $self->_debug("added $test lines at $line ($count directed)"); 
 
    } elsif ( $delta =~ /^d(\d+) (\d+)$/ ) { 

      my $first_line = $1;
      my $last_line  = $1 + $2 - 1;
      for my $line ( $first_line .. $last_line ) {
        $doc->{body}->{$line}->{line} = undef;
      }
      $self->_debug("deleting lines $first_line through $last_line ($2 directed)"); 
    } else { 
      warn "ORPHAN DELTA COMMAND! $delta\n"; 
    }
  }
  return 1;
}

sub _create_full_revision_path {
  my $self = shift @_;
  $self->_debug('Building full revision path for reference...');

  $self->{rcs}->{revision_path} = {};
  $self->{rcs}->{reverse_revision_path} = {};
  
  my $version = $self->recent_version;
  while ( my $next = $self->{rcs}->{$version}->{next} ) {
    $self->{rcs}->{revision_path}->{$version} = $next;
    $self->_debug("  $version -> $next");
    $version = $next;
  }

  #map { $self->{rcs}->{reverse_revision_path}->{$self->{rcs}->{revision_path}->{$_}} = $_ } keys %{$self->{rcs}->{revision_path}};

  $self->_debug('Built a revision path of ' . scalar( keys %{$self->{rcs}->{revision_path}} ) . ' jumps.');
}

sub _debug {
  my $self = shift @_;
  my $mesg = shift @_;
  chomp $mesg;
  print "DEBUG: $mesg\n" if $self->{debug};
}

sub _dump {
  my $self = shift @_;
  my $doc  = shift @_ || $self->{current_document};
  return join '', map { $doc->{body}->{$_}->{line} } sort { $a <=> $b } keys %{ $doc->{body} };
}

sub _parse_in_rcs {
  my $self = shift @_;
  my $rcs  = shift @_;

  ### Parse in the RCS file header

  my $rcs_header;

  while ( $self->{rawfile} =~ /\G(.+)\n/gcm ) {
    $rcs_header .= $1;
    $self->_debug("Adding line to the raw header.");
  }

  for my $chunk ( split /;/, $rcs_header ) {
    $chunk =~ s/\n//g;
    $chunk =~ /^\s*(\w+)\s*(.*)$/;
    $rcs->{header}->{$1} = $2 if $1;
  }

  $rcs_header = undef;

  ### Blank lines
  
  1 while ( $self->{rawfile} =~ /\G\n/gcm );
  
  ### Parse in the individual version headers

  while ( $self->{rawfile} =~ /\G(\d(\.|\d)+)(.+?)\n\n/gcs ) {
    $rcs->{$1}->{header} = $2;    
    $self->_debug("vheader $1 is ".length($1)." chars in size") if $self->{debug};
  }

  ### Blank lines
  
  1 while ( $self->{rawfile} =~ /\G\n/gcm );

  ### Parse in the desc

  if ( $self->{rawfile} =~ /\Gdesc\n\@\@\n/gcs || $self->{rawfile} =~ /\Gdesc\n\@(.+?)(?<!\@)\@\n/gcs ) {
    $rcs->{desc} = $1;
  }

  ### Blank lines
  
  1 while ( $self->{rawfile} =~ /\G\n/gcm );

  ### Change directives

  while ( $self->{rawfile} =~ /\G(\d(\.|\d)+)\n/gcm ) {
    my $version = $1;

    while ( $self->{rawfile} =~ /\G(\w+)\n\@\@\n/gcs || $self->{rawfile} =~ /\G(\w+)\n\@(.+?)(?<!\@)\@\n/gcs ) {
      $rcs->{$version}->{$1} = $2;
      $self->_debug("directive '$1' for ver $version is ".length($2)." chars in size") if $self->{debug};
    }

    1 while ( $self->{rawfile} =~ /\G\n/gcm ); # Blank lines
  }

  ### blank lines

  1 while ( $self->{rawfile} =~ /\G\n/gcm );

  $self->{finalpos} = pos($self->{rawfile}); # Done parsing? Remember position.

  ### disassemble header

  for my $version ( keys %$rcs ) {
    my @commands;
    @commands = split ';', $rcs->{$version}->{header} if defined $rcs->{$version}->{header};
    for my $command ( @commands ) {
      chomp $command;
      $rcs->{$version}->{$1} = $2 if $command =~ /\s*(.+)\s+(.+)$/;
    }
  }

  return 1;
}

sub _revision_path {
  my $self = shift @_;
  my $ver  = shift @_ || $self->recent_version;
  my $stop = shift @_ || undef;
  
  return undef unless $self->{rcs}->{$ver};
  return () if $ver eq $stop;  
  
  $self->_debug('Checking revision path...');
  $self->_create_full_revision_path() unless $self->{rcs}->{revision_path};

  my @chain;
  while ( my $next = $self->{rcs}->{revision_path}->{$ver} ) { 
    push @chain, $next;
    last if $next eq $stop;
    $ver = $next;
  }  

   $self->_debug("CHAIN: " . (join ' -> ', @chain));
  return @chain;
}

sub _sort {
  my $self = shift @_;
  my %copy = %{ $self->{current_document} };

  $self->{current_document} = {};
  $self->{current_document}->{version} = $copy{version};

  my $count = 1;
  for my $line_num ( sort { $a <=> $b } keys %{ $copy{body} } ) {
    # add basic line
    if ( $copy{body}{$line_num}{line} ) {
      $self->{current_document}->{body}->{$count}->{line} = $copy{body}{$line_num}{line};
      $self->{current_document}->{line_map}->{$count} = $line_num;
      $count++;
    }
    # add new lines if existant
    if ( $copy{body}{$line_num}{new_lines} ) {
      for my $line ( @{ $copy{body}{$line_num}{new_lines} } ) {
        $self->{current_document}->{body}->{$count}->{line} = $line;
        $count++;
      }
    }
  }

  %copy = ();

  $self->_debug( "($self->{current_document}->{version}) " . --$count . ' lines sorted...');

  return 1;
}

sub _unquote {
  my $self = shift @_;
  my $in   = shift @_;
  $in =~ s/\@\@/\@/g;
  return $in;
}

1;

=head1 KNOWN ISSUES

Beta Code:

This code is beta. It has yet to fully understand binary formats stored
in RCS and will treat them as text. Consquently, you'll see warnings. That
being said, there shouldn't be any large scale bugs that will cause
segfaulting or crashing. Only warnings.

The RCS file format:

There is an astounding lack of good documentation of the RCS format. About
the only thing that can be found is the rcsfile(5) man page. The layout is
mostly reverse engineered in this module. I have yet to have the time, or
the skill and patience to disassemble the RCS portions of the code for GNU
CVS.

=head1 ERATTA

  Q: Why 'Rcs' and not 'RCS'

  A: Because the any directory named 'RCS' is usually ignored by most 
     versioning software and some developer tools. 

=head1 BUGS AND SOURCE

	Bug tracking for this module: https://rt.cpan.org/Dist/Display.html?Name=Rcs-Parser

	Source hosting: http://www.github.com/bennie/perl-Rcs-Parser

=head1 VERSION

    Rcs::Parser v0.08 (2014/03/09)

=head1 COPYRIGHT

    (c) 2001-2014, Phillip Pollard <bennie@cpan.org>

=head1 LICENSE

This source code is released under the "Perl Artistic License 2.0," the text of 
which is included in the LICENSE file of this distribution. It may also be 
reviewed here: http://opensource.org/licenses/artistic-license-2.0
