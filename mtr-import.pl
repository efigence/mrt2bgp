#!/usr/bin/perl
use v5.10;
use Net::BGP::Process;
use Net::BGP::Peer;
use Net::BGP::Update;
use Data::Dumper;
use List::Flatten;
use Log::Any qw($log);
use Log::Any::Adapter ('Stderr');
my $MY_AS = '34209';
my $MY_IP = "10.205.0.2";
my $i;
my $file = '/var/tmp/latest-bview';




$bgp  = Net::BGP::Process->new(ListenAddr => '10.205.0.2');
$peer = Net::BGP::Peer->new(
    Start    => 1,
    ThisID   => $MY_IP,
    ThisAS   => $MY_AS,
    PeerID   => '10.205.0.1',
    PeerAS   => 43091,
    OpenCallback         => \&bgp_open_cb,
    KeepaliveCallback    => \&bgp_keepalive_cb,
    UpdateCallback       => \&bgp_update_cb,
    NotificationCallback => \&bgp_notification_cb,
    ErrorCallback        => \&bgp_error_cb,

);
my $run_import = 0;
my $import_done = 0;
my $bgpdump_fd;
$bgp->add_peer($peer);
$peer->add_timer(\&send_update, 3);
# eval {
#     open(C, '<', '/var/tmp/latest-bview');
#     binmode(C);
#     while ($decode = Net::MRT::mrt_read_next(C)) {
#         #    say "bits ->$decode->{'bits'} subtype => $decode->{'subtype'}";
#         print Dumper $decode if $decode->{'subtype'} > 2;
#     }
# };
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
    $log->info("Notification from AS" . $self->peer_as() . ":" . $self->peer_id())
}
sub bgp_error_cb {
    my $self = shift;
    local $log->context->{args}= \@_;
    $log->info("Error from AS" . $self->peer_as() . ":" . $self->peer_id())
}


sub peer_debug_callback {
    my $self = shift;
    say "AS" . $self->peer_as() . ":" . $self->peer_id();
    print Dumper @_;
    return;
}


sub send_update {
    my $self = shift;
    if($import_done) {return}
    if (!$run_import) {
        say "not sending update ";
        return;
    }
    say "sending update ";
    say $i;
    if (!defined($fd)) {
        open($fd, '-|','bgpdump','-v','-m',$file);
    }
    my $prev_net="0";
    my $loop_cnt = 0;
    my $route_cnt = 0;
    while (my $line = <$fd>) {
        #drop after 50k to give time for BGP to keepalive
        # probably should be clock based
        if ($loop_cnt++ > 500000 ) {
            $log->info("imported $i routes, giving BGP time to rest after $loop_cnt updates parsed");
            return;
        }
        if ($route_cnt > 50000 ) {
            $log->info("imported $i routes, giving BGP time to rest after $route_cnt routes sent");
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
            $i++;
        }
    }
    $run_import = 0;
    $import_done=1;
    close($fd);
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


# $VAR1 = {
#           'prefix' => '1.10.74.0',
#           'bits' => 24,
#           'subtype' => 2,
#           'entries' => [
#                          {
#                            'AS_PATH' => [
#                                           58308,
#                                           3356,
#                                           3491,
#                                           133741
#                                         ],
#                            'ORIGIN' => 0,
#                            'COMMUNITY' => [
#                                             '3356:2',
#                                             '3356:86',
#                                             '3356:500',
#                                             '3356:666',
#                                             '3356:2064',
#                                             '3491:400',
#                                             '3491:402',
#                                             '3491:62140',
#                                             '3491:62150'
#                                           ],
#                            'NEXT_HOP' => [
#                                            '37.49.236.172'
#                                          ],
#                            'originated_time' => 1507765032,
#                            'peer_index' => 28
#                          },
#                        ],
#           'type' => 13,
#           'timestamp' => 1508140800,
#           'sequence' => 266
#         };

#
#    TABLE_DUMP2|1506816000|B|37.49.236.1|8218|1.0.128.0/17|8218 6461 2914 38040 9737|IGP|37.49.236.1|0|0|8218:103 8218:20000 8218:20110|AG|9737 203.113.12.254|
# |AG| means aggregated |NAG| means not aggregated

sub bgpdump2update {
    my($type, # TABLE_DUMP2
       $ts, # UNIX TS
       $_unk1, # always B no idea what it is
       $router_ip,
       $router_as,
       $network,
       $as_path,
       $origin,
       $nexthop,
       $_unk2, # ?localpref?
       $med,
       $community,
       $aggregated,
       $aggregator,
   ) = @_;
    if($type ne 'TABLE_DUMP2' || $_unk1 ne 'B') {
        $log->error("[bgpdump]no idea what line [$line] represents, cant decipher");
        return undef;
    }
    my @as_path = flat($MY_AS, split(/\s+/,$as_path_raw));
    my @community = split(split(/\s+/,$community));
    $update = Net::BGP::Update->new(
        NLRI            => [ $network ],
        #        Withdraw        => [ qw( 192.168.1/24 172.10/16 192.168.2.1/32 ) ],
        # For Net::BGP::NLRI
        #           Aggregator      => [ 34209, '10.0.205.2' ],
        AsPath          => \@as_path,
        # AtomicAggregate => 1,
        Communities     => \@community,
        #LocalPref       => 100,
        MED             => $med || 0,
        NextHop         => $MY_IP,
        Origin          => INCOMPLETE, #EGP, # IGP/EGP/INCOMPLETE
    )
}



sub mrt2updates {
    my $mrt = shift;
    my @updates;
    if ($mrt->{'subtype'} != 2 && $mrt->{'subtype'} != 8 ) {
        return \@updates
    }
    for my $entry (@{$mrt->{'entries'}}) {
        my @as_path = flat($MY_AS, flat(@{$entry->{'AS_PATH'}}) );

        $update = Net::BGP::Update->new(
            NLRI            => [ $mrt->{'prefix'} . "/" . $mrt->{'bits'} ],
            #        Withdraw        => [ qw( 192.168.1/24 172.10/16 192.168.2.1/32 ) ],
            # For Net::BGP::NLRI
            Aggregator      => [ 34209, '10.0.205.2' ],
            AsPath          => \@as_path,
            AtomicAggregate => 1,
            Communities     => $entry->{'COMMUNITY'}|| [],
#            LocalPref       => 100,
            MED             => $entry->{'MULTI_EXIT_DISC'} || 100,
            NextHop         => $MY_IP,
            Origin          => $entry->{'ORIGIN'}, #EGP, # IGP/EGP/INCOMPLETE
        );
        push(@updates, $update);
    }
    return \@updates
}
