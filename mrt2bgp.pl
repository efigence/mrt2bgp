#!/usr/bin/perl
use v5.10;
use strict;
use warnings;
use Net::BGP::Process;
use Net::BGP::Peer;
use Net::BGP::Update;
use Data::Dumper;
use List::Flatten;
use Carp qw(croak cluck carp confess);
use Getopt::Long qw(:config auto_help);
use Pod::Usage;
use Log::Any qw($log);
use Log::Any::Adapter ('Stderr');

my $cfg = { # default config values go here
    'file'    => '/var/tmp/latest-bview',
    'bind-ip' => '127.0.1.2',
    'bind-port' => '17900',
    'local-ip' => '127.0.1.2',
    'local-as' => '65002',
    'peer-ip' => '127.0.1.1',
    'peer-as' => '65001',
    'exit-on-error' => 1,
};
my $help;

GetOptions(
    'file=s'    =>  \$cfg->{'file'},
    'bind-ip=s'    =>  \$cfg->{'bind-ip'},
    'bind-port=s'    =>  \$cfg->{'bind-port'},
    'local-ip=s'    =>  \$cfg->{'local-ip'},
    'local-as=s'    =>  \$cfg->{'local-as'},
    'peer-ip=s'    =>  \$cfg->{'peer-ip'},
    'peer-as=s'    =>  \$cfg->{'peer-as'},
#    'daemon'        => \$cfg->{'daemon'},
#    'pidfile=s'       => \$cfg->{'pidfile'},
    'help'          => \$help,
) or pod2usage(
    -verbose => 2,  #2 is "full man page" 1 is usage + options ,0/undef is only usage
    -exitval => 1,   #exit with error code if there is something wrong with arguments so anything depending on exit code fails too
);

# some options are required, display short help if user misses them
my $required_opts = [ ];
my $missing_opts;
foreach (@$required_opts) {
    if (!defined( $cfg->{$_} ) ) {
        push @$missing_opts, $_
    }
}

if ($help || defined( $missing_opts ) ) {
    my $msg;
    my $verbose = 2;
    if (!$help && defined( $missing_opts ) ) {
        $msg = 'Opts ' . join(', ',@$missing_opts) . " are required!\n";
        $verbose = 1; # only short help on bad arguments
    }
    pod2usage(
        -message => $msg,
        -verbose => $verbose, #exit code doesnt work with verbose > 2, it changes to 1
    );
}

if (defined($cfg->{'prepend-as'})) {
    my @prepend = split(/(,|\s)+/,$cfg->{'prepend-as'});
    $cfg->{'prepend-as'} = \@prepend;
}



my $bgp  = Net::BGP::Process->new(ListenAddr => $cfg->{'bind-ip'}, Port => $cfg->{'bind-port'});
my $peer = Net::BGP::Peer->new(
    Start    => 1,
    ThisID   => $cfg->{'local-ip'},
    ThisAS   => $cfg->{'local-as'},
    PeerID   => $cfg->{'peer-ip'},
    PeerAS   => $cfg->{'peer-as'},
    OpenCallback         => \&bgp_open_cb,
    KeepaliveCallback    => \&bgp_keepalive_cb,
    UpdateCallback       => \&bgp_update_cb,
    NotificationCallback => \&bgp_notification_cb,
    ErrorCallback        => \&bgp_error_cb,

);
my $run_import = 0;
my $import_done = 0;
my $bgpdump_fd;
my $bgpdump_pid;
my $total_route_cnt = 0;
my $total_update_cnt = 0;
my $i = 0;
$bgp->add_peer($peer);
$peer->add_timer(\&send_update, 1);
$bgp->event_loop();

sub bgp_open_cb {
    my $self = shift;
    $run_import = 1;
    local $log->context->{args}= \@_;
    $log->info("Opened connection from AS" . $self->peer_as() . ":" . $self->peer_id());
}
sub bgp_keepalive_cb {
    my $self = shift;
    $log->info("Keepalive from AS" . $self->peer_as() . ":" . $self->peer_id())
}
sub bgp_update_cb {
    my $self = shift;
    $log->info("Update from AS" . $self->peer_as() . ":" . $self->peer_id())
}
sub bgp_notification_cb {
    my $self = shift;
    local $log->context->{args}= \@_;
    $log->info("Notification from AS" . $self->peer_as() . ":" . $self->peer_id())
}
sub bgp_error_cb {
    my $self = shift;
    local $log->context->{args}= \@_;
    $log->info("Error from AS" . $self->peer_as() . ":" . $self->peer_id());
    if ($cfg->{'exit-on-error'}) {
        exit_cleanup()
    }
}
sub exit_cleanup {
    if (defined($bgpdump_fd)) {
        # bgpdump will just happily push data making close very slow; kill it before closing
        say "waiting for bgpdump to stop";
        if ($bgpdump_pid > 10) {
            system('kill',$bgpdump_pid);
        }
        close($bgpdump_fd);
        if ($bgpdump_pid > 100) {

        }

        waitpid $bgpdump_pid, 0;
    }
    say "exiting";
    exit 0;
}



sub peer_debug_callback {
    my $self = shift;
    say "AS" . $self->peer_as() . ":" . $self->peer_id();
    print Dumper @_;
    return;
}


sub send_update {
    my $self = shift;
    if (!$run_import) {
        return;
    }
    say "sending update $i";
    if (!defined($bgpdump_fd)) {
       $bgpdump_pid = open($bgpdump_fd, '-|','bgpdump','-v','-m',$cfg->{'file'}) or croak ("Can't open dump file: $!");
    }
    my $prev_net="0";
    my $loop_cnt = 0;
    my $route_cnt = 0;
    while (my $line = <$bgpdump_fd>) {
        #drop after 50k to give time for BGP to keepalive
        # probably should be clock based
        $total_update_cnt++;
        if ($loop_cnt++ > 500000 ) {
            $log->info("imported $i routes, sleeping, $loop_cnt updates parsed");
            return;
        }
        if ($route_cnt > 50000 ) {
            $log->info("imported $i routes, sleeping, $route_cnt routes sent");
            return;
        }

        chomp($line);
        if ($line =~ /::/) {next}
        my @raw= split(/\|/,$line);
        my $net = $raw[5];
        if ($net ne $prev_net) {
            my $update = bgpdump2update(@raw);
            $self->update($update);
            $prev_net = $net;
            $route_cnt++;
            $total_route_cnt++;
            $i++;
        }
    }
    $log->info("done importing, $total_route_cnt routes within $total_update_cnt updates");
    $run_import = 0;
    close($bgpdump_fd);
};
#    $update = Net::BGP::Update->new(
#         NLRI            => [ qw( 10.111.11.0/24 ) ],
# #        Withdraw        => [ qw( 192.168.1/24 172.10/16 192.168.2.1/32 ) ],
#         # For Net::BGP::NLRI
#         Aggregator      => [ 34209, '10.0.205.2' ],
#         AsPath          => [ 34209, 64512, 64513, 64514 ],
#         AtomicAggregate => 1,
#         Communities     => [ qw( 64512:10000 64512:10001 ) ],
#         LocalPref       => 100,
#         MED             => 200,
#         NextHop         => '10.0.205.4',
#         Origin          => INCOMPLETE, # IGP/EGP/INCOMPLETE
#     );
 #   $self->update($update);
sub bgpdump2update {
    my($type, # TABLE_DUMP2
       $ts, # UNIX TS
       $_unk1, # always B no idea what it is
       $router_ip,
       $router_as,
       $network,
       $as_path_raw,
       $origin,
       $nexthop,
       $_unk2, # ?localpref?
       $med,
       $community_raw,
       $aggregated,
       $aggregator,
   ) = @_;
    if($type ne 'TABLE_DUMP2' || $_unk1 ne 'B') {
        $log->error("[bgpdump]no idea what [$@] represents, cant decipher");
        return undef;
    }
    my @as_path;
    if (defined($cfg->{'prepend-as'})) {
        @as_path = flat(@{$cfg->{'prepend-as'}}, split(/\s+/,$as_path_raw));
    } else {
        @as_path = split(/\s+/,$as_path_raw);
    }
    my @community = split(/\s+/,$community_raw);
    if (defined $cfg->{'nexthop'})  {
        $nexthop = $cfg->{'nexthop'}
    }
    my $update = Net::BGP::Update->new(
        NLRI            => [ $network ],
        #        Withdraw        => [ qw( 192.168.1/24 172.10/16 192.168.2.1/32 ) ],
        # For Net::BGP::NLRI
        #           Aggregator      => [ 34209, '10.0.205.2' ],
        AsPath          => \@as_path,
        # AtomicAggregate => 1,
        Communities     => \@community,
        #LocalPref       => 100,
        MED             => $med || 0,
        NextHop         => $nexthop,
        Origin          => $origin, #EGP, # IGP/EGP/INCOMPLETE
    );

    return $update;
}

=head1 MRT2BGP

mrt2bgp.pl - Push MRT dump via bgp

=head1 SYNOPSIS

./mrt2bgp.pl  --local-ip 10.20.0.2 --bind-ip 10.20.0.2 --peer-ip 10.20.0.1

=head1 DESCRIPTION

Push MRT dump via bgp with option for some light filtering and modification

=head1 OPTIONS

parameters can be shortened if unique, like  --file -> -f

=over 4

=item B<--file>  /var/tmp/latest-bview

MRT dump file

=item B<--bind-ip> 127.0.1.2

IP to bind listener

=item B<--bind-port> 17900

Port to use. NOTE that default is 17900 (so you dont need root), but bgp canonical port is actually 179 so you will need to change it (and give root or setcap) for it to work with non-soft router

=item B<--local-ip> 127.0.1.2

IP for local side of connection - should be set to same as bind IP

=item B<--local-as> 65002

Local AS number

=item B<--peer-ip> 127.0.1.1

Peer IP

=item B<--peer-as>

Peer AS


=item B<--help>

display full help

=back

=head1 EXAMPLES

=over 4

=item B<carton run ./mrt-import.pl  --local-ip 10.205.0.2 --bind-ip 10.205.0.2 --peer-ip 10.205.0.1>

Set local and peer IP


=back
