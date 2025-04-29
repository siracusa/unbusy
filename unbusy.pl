#!/usr/bin/env perl

use strict;
use warnings;

use IPC::Cmd;
use Getopt::Long;

Getopt::Long::config('auto_abbrev');

my %Opts;

GetOptions(\%Opts, 'debug', 'help') or Usage(1);
Usage()  if ($Opts{'help'} || !@ARGV);

my $Debug = $Opts{'debug'};

use constant XATTR => '/usr/bin/xattr';

MAIN: {
    my $exit_status = 0;

    foreach my $file (@ARGV) {
        my (%error, $stderr);

        # Read the 32-byte com.apple.FinderInfo xattr has a hex dump
        my $hex = CommandOutput({
            command  => [ XATTR, '-px', 'com.apple.FinderInfo', $file ],
            error    => \%error,
            stderr   => \$stderr,
            nonfatal => 1,
            debug    => $Debug,
        });

        unless (defined($hex)) {
            unless ($error{'stderr'} =~ /\bNo such xattr\b/) { # :-/
                warn "Could not read com.apple.FinderInfo xattr from '$file' - $error{message}",
                    ($stderr =~ /\S/ ? $stderr : ''), "\n";
                $exit_status = 1;
            }

            $Debug && print "No com.apple.FinderInfo xattr found for '$file'\n";
            next;
        }

        $hex =~ s/\s+//g;

        my $buf = pack("H*", $hex);

        if (length($buf) > 32) {
            warn "Got unexpected com.apple.FinderInfo xattr length from '$file' - ", length($buf), "\n";
            $exit_status = 1;
            next;
        }

        $buf .= "\0" x (32 - length($buf));

        # Clear the busy bit in the extended flags
        my $ext_flags = unpack("n", substr($buf, 24, 2));
        $ext_flags &= ~0x0080;
        substr($buf, 24, 2, pack("n", $ext_flags));

        my $new_hex = unpack("H*", $buf);

        %error = ();
        $stderr = undef;

        my $output = CommandOutput({
            command  => [ XATTR, '-wx', 'com.apple.FinderInfo', $new_hex, $file ],
            error    => \%error,
            stderr   => \$stderr,
            nonfatal => 1,
            debug    => $Debug,
        });

        if (defined($output)) {
            $Debug && print "Busy bit cleared for file '$file'\n";
        }
        else {
            warn "Could not write updated com.apple.FinderInfo xattr to '$file' - $error{message}",
                ($stderr =~ /\S/ ? $stderr : ''), "\n";
            $exit_status = 1;
        }
    }

    exit($exit_status);
}

#########################################################################################
# Usage
#
# Description:
#   Print the usage message for this script to stderr, then exit.
#
# Parameters:
#   An optional status value to pass to exit(). Defaults to 0.
#
# Return Value:
#   Not meaningful.
#########################################################################################
sub Usage {
    (my $script = $0) =~ s{.*/}{};

    print STDERR<<"EOF";
Usage: $script [--debug] file1 [file2 ...] | --help
--debug  Print debugging output.
--help   Show this help screen.
EOF

    exit($_[0] || 0);
}

#########################################################################################
# CommandOutput
#
# Description:
#   Run a command and return the output, handling errors (if any).  Only the STDOUT
#   output is returned by default.  See the optional "combined" and "stderr" parameters
#   for more options.
#
# Parameters:
#   A list of command arguments, a reference to an array of command arguments, or a
#   reference to a hash of parameters:
#
#   Required:
#
#   command - A command string or a reference to an array of command arguments.
#
#   Optional:
#
#   combined - If true, return the combined STDOUT and STDERR output of the command.
#
#   debug    - If true, debugging output will be printed to STDERR via warn()
#
#   error    - A reference to a hash that will contain error conditions if the command
#              did not execute successfully.  Hash keys are:
#
#                  message - The error message.
#
#                  output  - The combined output of the command, if combined is set.
#
#                  stderr  - The STDERR output of the command.
#
#                  stdout  - The STDOUT output of the command.
#
#   nonfatal - Don't die if the command didn't execute successfully and exit with
#              a 0 value.
#
#   stderr   - A reference to a scalar in which to store the STDERR output of the
#              command.
#
# Return Value:
#   The output of the command or undef if there was an error.
#
#   NOTE: This function die()s if the command didn't execute successfully (i.e., exit
#   with a 0 value) and the nonfatal parameter is not set to true.
#########################################################################################
sub CommandOutput {
    my ($args) = $_[0];

    my $command;

    if (ref $args eq ref {}) {
        $command =  $args->{'command'};
        $command = [ $command ]  unless(ref $command);
    }
    elsif (ref $args eq ref []) {
        $command = $args;
        $args = {};
    }
    elsif (!ref $args) {
        $command = [ @_ ];
        $args = {};
    }

    my $error = $args->{'error'} || {};

    $args->{'debug'} && warn "Run: @$command\n";

    my($ok, $error_message, $buffer, $stdout, $stderr) =
        IPC::Cmd::run(command => $command, verbose => 0);

    if ($args->{'stderr'}) {
        ${$args->{'stderr'}} = join('', @$stderr);
    }
    elsif (!$args->{'combined'}) {
        print STDERR join('', @$stderr);
    }

    unless ($ok) {
        die "Command '@$command' failed to execute and exit cleanly - $error_message"
            unless ($args->{'nonfatal'});

        $error->{'stderr'}  = join('', @$stderr);
        $error->{'stdout'}  = join('', @$stdout);
        $error->{'output'}  = join('', @$buffer);
        $error->{'message'} = $error_message;

        return undef;
    }

    return $args->{'combined'} ? join('', @$buffer) : join('', @$stdout);
}
