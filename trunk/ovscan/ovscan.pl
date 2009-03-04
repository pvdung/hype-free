#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use Digest::MD5;
use HTTP::Request::Common;
use Getopt::Long;
use English;

#    Copyright 2007 Cd-MaN
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.

#don't load the file in memory at once to conserve memory
$HTTP::Request::Common::DYNAMIC_FILE_UPLOAD = 1;

our $version = "0.3";

our $verbose;
our $display_help;
our $distribute;
our ($output_bbcode, $output_csv, $ouput_tab, $output_html);
our $log_file;

if (!GetOptions("verbose|v" => \$verbose,
  "help|h" => \$display_help,
  "no-distrib|n" => \$distribute,
  "bb-code|b" => \$output_bbcode, 
  "csv|c" => \$output_csv, 
  "tab|t" => \$ouput_tab, 
  "html|m" => \$output_html,
  "log|l=s" => \$log_file) || $display_help) {
  help();
  exit;
}
$distribute = !$distribute;

if (defined($log_file)) {
  open FOUT, '>', $log_file;
} else {
  open FOUT, ">&STDOUT";
}

my %processed_cache;
our $browser = LWP::UserAgent->new(agent => "unoffical vtuploader/v$version contact: x_at_y_or_z\@yahoo.com",
  requests_redirectable => []);
#grab the proxy settings from the enviroment variables
#if it's the case
$browser->env_proxy();

foreach my $glob_str (@ARGV) {
  foreach my $file_name (glob($glob_str)) {
    next unless (-f $file_name);
    if (-s $file_name > 10_000_000) {
      print STDERR "The maximum file size allowed is 10M. The \"$file_name\" exceeds this limit!\n";
      next;
    }
    if (-s $file_name == 0) {
      print STDERR "File \"$file_name\" has size zero. Will not be scanned\n";
      next;
    }
    
    #don't die if an error occured, since this is a lengthy process
    #and we should process at least the files which we can
    eval {
      print STDERR "Processing file $file_name\n" if ($verbose);
      
      #calculate the MD5 of the file and try to find out
      #if an identical file has already been process
      #and if so, display the results from there

      my ($file_md5, $file_size) = (md5_file($file_name), -s $file_name);
      print STDERR "\tMD5: $file_md5\n\tFile size: $file_size bytes\n" if ($verbose);
      
      my $found_in_cache = 0;
      foreach my $processed_file_name (keys %processed_cache) {
        if ($file_md5 eq $processed_cache{$processed_file_name}->{'MD5'} &&
          $file_size == $processed_cache{$processed_file_name}->{'size'} &&
          files_identical($processed_file_name, $file_name)) {
          print STDERR "\tFile identical to \"$processed_file_name\". Will display cached results\n" if ($verbose);
          $processed_cache{$file_name} = $processed_cache{$processed_file_name}; 
          $found_in_cache = 1;
          last;
        }
      }
      if (!$found_in_cache) {
        my $result = process_file($file_name);				
        $processed_cache{$file_name} = {
          'MD5' => $file_md5,
          'size' => $file_size,
          'result' => $result
        };
      }
      
      if ($verbose) {
        my $infected = 0;
        foreach my $av_engine (keys %{$processed_cache{$file_name}->{'result'}}) {
          next if (('sha1' eq $av_engine) or ('md5' eq $av_engine) or ('size' eq $av_engine));
          $infected++ if ($processed_cache{$file_name}->{'result'}->{$av_engine}->{'scan_result'} ne '-');
        }
        my $total_engines = scalar(keys %{$processed_cache{$file_name}->{'result'}}) - 3;
        print STDERR "Infection count $infected out of $total_engines\n";
      }			
    };
    print STDERR "The following error occured while processing \"$file_name\":\n$@\n" if ($@);
  }
}

my ($max_av_engine_name, $max_av_version, $max_last_update, $max_result, $max_file_name) = 
  (length "Antivirus", length "Version", length "Last Update", length "Result", 0);
my %av_engine_names;
foreach my $file_name (keys %processed_cache) {
  $max_file_name = length($file_name) if (length($file_name) > $max_file_name);
  my %file_results = %{$processed_cache{$file_name}->{'result'}};
  foreach my $engine_name (keys %file_results) {
    next if (('sha1' eq $engine_name) or ('md5' eq $engine_name) or ('size' eq $engine_name));
    $av_engine_names{$engine_name} = 1;
    $max_av_engine_name = length($engine_name) if (length($engine_name) > $max_av_engine_name);
    $max_av_version     = length($file_results{$engine_name}->{'version'}) if (length($file_results{$engine_name}->{'version'}) > $max_av_version);
    $max_last_update    = length($file_results{$engine_name}->{'last_update'}) if (length($file_results{$engine_name}->{'last_update'}) > $max_last_update);
    $max_result         = length($file_results{$engine_name}->{'scan_result'}) if (length($file_results{$engine_name}->{'scan_result'}) > $max_result);
  }
}
my @engine_name_list = sort keys %av_engine_names;

if ($output_csv || $ouput_tab) {
  my $separator = ($output_csv) ? ', ' : "\t";
  my @columns = (
    "File name",
    "Size",
    "MD5",
    "SHA1",
    "Dectection count",
    "Percentage",
    (map { ($_, "Version", "Last update", "Result") } @engine_name_list)
  );
  @columns = map { quote_elements($_) } @columns if ($output_csv);
  
  print FOUT join($separator, @columns), "\n";
}

foreach my $processed_file (sort keys %processed_cache) {
  my %file_results = %{$processed_cache{$processed_file}->{'result'}};
  
  my ($detection_count, $total_count) = (0, 0);
  foreach my $av_engine (@engine_name_list) {
    next if (('sha1' eq $av_engine) or ('md5' eq $av_engine) or ('size' eq $av_engine));
    $detection_count++ if ($processed_cache{$processed_file}->{'result'}->{$av_engine}->{'scan_result'} ne '-');  	
    $total_count++;
  }
  my $percent_detection = sprintf("%.2f%%", (0 == $total_count) ? 0.0 : $detection_count * 100.0 / $total_count);

  if ($output_bbcode) {
    print FOUT "[pre]\n";
    print FOUT "---[ [url]www.virustotal.com[/url] ]---------------------------\n";
    print FOUT "\nFile $processed_file\n";
    print FOUT "Detection: $percent_detection ($detection_count/$total_count)\n\n";
    
    print FOUT left_align($max_av_engine_name, "Antivirus") . " " . left_align($max_av_version, "Version") . " " .
      left_align($max_last_update, "Last Update") . " " . left_align($max_result, "Result") . "\n";
    foreach my $av_engine (@engine_name_list) {
      next if (('sha1' eq $av_engine) or ('md5' eq $av_engine) or ('size' eq $av_engine));
      my $result = $file_results{$av_engine}->{'scan_result'};
      $result = "[color=red]no virus found[/color]" if ('-' eq $result);
      print FOUT left_align($max_av_engine_name, $av_engine) . " " . left_align($max_av_version, $file_results{$av_engine}->{'version'}) . " " .
        left_align($max_last_update, $file_results{$av_engine}->{'last_update'}) . " $result\n";
    }
    
    print FOUT "\nAdditional information\n\n";
    print FOUT "File size: " . $file_results{'size'} . " bytes\n";
    print FOUT "MD5: " . $file_results{'md5'} . "\n";
    print FOUT "SHA1: " . $file_results{'sha1'} . "\n";
    print FOUT "[/pre]\n\n";
  } elsif ($output_csv || $ouput_tab) {
    my @columns = (
      $processed_file,
      $file_results{'size'},
      $file_results{'md5'},
      $file_results{'sha1'},
      $detection_count,
      $percent_detection
    );
    foreach my $av_engine (@engine_name_list) {
      next if (('sha1' eq $av_engine) or ('md5' eq $av_engine) or ('size' eq $av_engine));
      push @columns, (
        $av_engine,
        $file_results{$av_engine}->{'version'},
        $file_results{$av_engine}->{'last_update'},
        $file_results{$av_engine}->{'scan_result'}
      );
    }
  
    my $separator = ($output_csv) ? ', ' : "\t";  	
    @columns = map { quote_elements($_) } @columns if ($output_csv);	
    print FOUT join($separator, @columns), "\n";  	
  } elsif ($output_html  ) {
    print FOUT <<END;
<table>
<caption><a href="http://www.virustotal.com/">VirusTotal</a> scan results</caption>
<thead>
<tr><th>File name</th><td colspan="3">$processed_file</td></tr>
<tr><th>Detection</th><td colspan="3">$percent_detection ($detection_count/$total_count)</td></tr>
<tr><th>Antivirus</th><th>Version</th><th>Last update</th><th>Result</th></tr>
</thead>
<tbody>  
END
    foreach my $av_engine (@engine_name_list) {
      next if (('sha1' eq $av_engine) or ('md5' eq $av_engine) or ('size' eq $av_engine));
      print FOUT "<tr><td>" . $av_engine . "</td><td>" . $file_results{$av_engine}->{'version'} . "</td><td>" . 
        $file_results{$av_engine}->{'last_update'} . "</td><td>" . $file_results{$av_engine}->{'scan_result'} . "</td></tr>\n";
    }						
    print FOUT <<END;
<tfoot>
<tr><th colspan="4">Additional information</th></tr>
<tr>
<th>File size:</th>
<td colspan="3">$file_results{'size'} bytes</td>
</tr>
<tr>
<th>MD5:</th>
<td colspan="3">$file_results{'md5'}</td>
</tr>
<tr>
<th>SHA1:</th>
<td colspan="3">$file_results{'sha1'}</td>
</tr>				
</tfoot>
</table>		
END
  } else {
    print FOUT "\nFile $processed_file\n";
    print FOUT "Detection: $percent_detection ($detection_count/$total_count)\n\n";
    
    print FOUT left_align($max_av_engine_name, "Antivirus") . " " . left_align($max_av_version, "Version") . " " .
      left_align($max_last_update, "Last Update") . " " . left_align($max_result, "Result") . "\n";
    foreach my $av_engine (@engine_name_list) {
      next if (('sha1' eq $av_engine) or ('md5' eq $av_engine) or ('size' eq $av_engine));
      print FOUT left_align($max_av_engine_name, $av_engine) . " " . left_align($max_av_version, $file_results{$av_engine}->{'version'}) . " " .
        left_align($max_last_update, $file_results{$av_engine}->{'last_update'}) . " " . $file_results{$av_engine}->{'scan_result'} . "\n";
    }
    
    print FOUT "\nAdditional information\n\n";
    print FOUT "File size: " . $file_results{'size'} . " bytes\n";
    print FOUT "MD5: " . $file_results{'md5'} . "\n";
    print FOUT "SHA1: " . $file_results{'sha1'} . "\n";  
  }
}

exit;

sub left_align {
  my ($size, @elements) = @_;
  my $element = join("", @elements);
  $element .= " " while (length($element) < $size);
  return $element;
}

sub right_align {
  my ($size, @elements) = @_;
  my $element = join("", @elements);
  $element = " " . $element while (length($element) < $size);
  return $element;
}

sub help {
  print <<END;
Version: $version
Usage:

$0 [options] [file masks]

Options:
  -n --no-distrib The sample is not distributed to AV vendors
  -h --help       Displays this help
  -v --verbose    Output detailed information about the progress
  -b --bb-code    Output the result as BBCode
  -c --csv        Output the result as CSV
  -t --tab        Output the result as tab delimited file
  -m --html       Output the result as HTML	
  -l --log=[file] Save the output (the result of the scans) to the specified day

File masks:
  Specifies a file or a group of files to upload and scan

END
}

our $last_printed_line_len = 0;

#used to overwrite the lines (for progress bars, etc)
sub print_line {
  return unless ($verbose);
  
  print STDERR "\r", " " x $last_printed_line_len, "\r";
  print STDERR join("", @_);
  $last_printed_line_len = length(join("", @_));
 }

sub process_file {
  my $file_name = shift;
  die("Tried to process elemetn \"$file_name\" which is not a file!\n") if (! -f $file_name);
  
  my $file_upload_request = POST 'http://www.virustotal.com/vt/en/recepcionf',
    [ 
      'archivo' => [ $file_name ],
      'distribuir' => $distribute
    ],
    'Content_Type' => 'form-data';
  
  my ($total_size, $sent_size) = (1 + -s $file_name, 0);
  
  if ($verbose) {
    my $content_generator = $file_upload_request->content();
    die ("Content expected to be code reference!\n") unless ref($content_generator) eq "CODE";
    print STDERR "\n";
    $file_upload_request->content(
      sub {
        my $chunk = &$content_generator();
        if (defined $chunk) {
          $sent_size += length $chunk;
          my $percentage = $sent_size * 100 / $total_size;
          $percentage = 100 if ($percentage > 100);
          print_line(sprintf("%.2f%% uploaded", $percentage));
        }
        return $chunk;
      }
    );
  }
  
  my $response = $browser->request($file_upload_request);
  print_line("");  
  
  die ("Response header does not contain expected location header!\n") 
    unless ($response->header('Location') =~ /\/([a-f0-9]+)$/i);
  my $file_id = $1;
  
  print STDERR "Upload finished, waiting for scanning\n" if ($verbose);
  
  my $scan_request = GET "http://www.virustotal.com/vt/en/resultado?$file_id-0-0",
    'Referrer' => "http://www.virustotal.com/resultado.html?$file_id";
  
  my %results;
  my $wait_timeout = 30; #in seconds;
  while (1) {
    $response = $browser->request($scan_request);
    my $response_parsed = quickNDirtyJSONParser($response->content());
    if ('ENCOLADO' eq $response_parsed->[0]) {
      print_line(sprintf("Enqued in position %d. Estimated start time between %d and %d %s", 
        $response_parsed->[3]->[0], $response_parsed->[3]->[1], $response_parsed->[3]->[2], $response_parsed->[3]->[3]));
    } elsif ('ANALIZANDO' eq $response_parsed->[0]) {
      print_line(sprintf("Scanning. Scanned with %d engines", scalar(@{$response_parsed->[3]})));
    } elsif ('REFRESCAR' eq $response_parsed->[0]) {
      print_line("Server requested us to wait");
      my $wait_amount = $response_parsed->[1];
      print STDERR "\n" if ($verbose);      
      for (1..$wait_amount) {
        print_line ("Waiting for ", ($wait_amount - $_), " more seconds");
        sleep 1;
      }      
    } elsif ('TERMINADO' eq $response_parsed->[0]) {
      print_line("Scanning done");
      foreach my $result (@{$response_parsed->[2]}) {
        $results{$result->[0]} = {
          'version' => $result->[1],
          'last_update' => $result->[2],
          'scan_result' => $result->[3]        
        };
      }
      $results{'md5'} = $1 if ($response_parsed->[3]->[1]->[0] =~ /([0-9a-fA-F]{32})/);      
      $results{'sha1'} = $1 if ($response_parsed->[3]->[2]->[0] =~ /([0-9a-fA-F]{40})/);      
      $results{'size'} = $1 if ($response_parsed->[3]->[0]->[0] =~ /(\d+) bytes/);
      
      last;
    } else {
      die("Unexpected status returned by server: " . $response_parsed->[0] . "\n");
    }
    print STDERR "\n" if ($verbose);
    
    for (1..$wait_timeout) {
      print_line ("Waiting for ", ($wait_timeout - $_), " more seconds");
      sleep 1;
    }
  };

  print STDERR "\n" if ($verbose);
  
  return \%results;		
}

sub md5_file {
  my $file_name = shift;
  open my $f_md5, $file_name or die("Failed to open \"$file_name\" to calculate its MD5: $!\n");
  binmode $f_md5;
  
  my $ctx = Digest::MD5->new;
  $ctx->addfile($f_md5);
  
  close $f_md5;
  return $ctx->hexdigest;	
}

sub files_identical {
  my ($file_name1, $file_name2) = @_;
  return 0 if (! -f $file_name1 || ! -f $file_name2);
  return 0 if (-s $file_name1 != -s $file_name2);
  
  open my $f1, $file_name1 or die("Failed to open \"$file_name1\": $!\n"); binmode $f1;
  open my $f2, $file_name2 or die("Failed to open \"$file_name1\": $!\n"); binmode $f2;
  
  while (1) {
    my ($buff1, $buff2, $buff1_size, $buff2_size);
    $buff1_size = read $f1, $buff1, 4096;
    die("Failed to read from \"$file_name1\": $!\n") if (!defined $buff1_size);
    $buff2_size = read $f2, $buff2, 4096;
    die("Failed to read from \"$file_name2\": $!\n") if (!defined $buff2_size);
    
    die("Something went horribly wrong! Buffer sizes should be equal!") if ($buff1_size != $buff2_size);
    last if ($buff1_size == 0);
    
    if ($buff1 ne $buff2) {
      close $f1; close $f2;
      return 0;		
    }
  }
  
  close $f1; close $f2;
  return 1;
}

#implements parsing for a subset of JSON
#used to make the script as self-contained as possible
sub quickNDirtyJSONParser {
  my $jsonStr = shift;
    
  my @parserStack;
  push @parserStack, [];
  
  while ('' ne $jsonStr) {
    #right trim
    $jsonStr =~ s/^\s+//;
    
    if ($jsonStr =~ /^\[/) {
      push @parserStack, [];
      $jsonStr = $POSTMATCH;
    } elsif ($jsonStr =~ /^\"((?:[^\"]|\\\")*)\"/) {
      my $str = $1; $jsonStr = $POSTMATCH;
      $str =~ s/\\\"/\"/g;
      $str =~ s/\\\\/\\/g;
      $str =~ s/\\\//\//g;
      $str =~ s/\\b/\b/g;
      $str =~ s/\\f/\f/g;
      $str =~ s/\\n/\n/g;
      $str =~ s/\\r/\r/g;
      $str =~ s/\\t/\t/g;
      #todo: handle unicode characters encoded as \uXXXX
      my $topOfStack = pop @parserStack;
      push @{$topOfStack}, $str;
      push @parserStack, $topOfStack;
    } elsif ($jsonStr =~ /^\]/) {			
      $jsonStr = $POSTMATCH;
      my ($topOfStack, $secondTopOfStack) = (pop @parserStack, pop @parserStack);
      push @{$secondTopOfStack}, $topOfStack;
      push @parserStack, $secondTopOfStack;
    } elsif ($jsonStr =~ /^,/) {
      $jsonStr = $POSTMATCH;
    } elsif ($jsonStr =~ /^\-?\d+(?:\.\d+)?(?:[eE][\+\-]?\d+)?/) {
      my $topOfStack = pop @parserStack;
      push @{$topOfStack}, (0.0 + $&);
      push @parserStack, $topOfStack;		
      $jsonStr = $POSTMATCH;
    } elsif ('' eq $jsonStr) {
      last;
    } else {
      die ("Unexpected token at >>>$jsonStr<<<\n");
    }
  }
  
  die("Something went horribly wrong! We should have exactly 1 element on the parse stack!\n") if (1 != scalar(@parserStack));
  return $parserStack[0]->[0];
}

#used to quote elements for csv's
sub quote_elements {
  if (/[\"\t]/) {
    s/\"/\"\"/g;
    return "\"$_\"";
  } else {
    return $_;
  }
}
