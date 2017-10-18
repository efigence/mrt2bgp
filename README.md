#### MRT2BGP

Tiny script that listens for BGP connection and dumps supplied MRT onto it.

### OPTIONS
    parameters can be shortened if unique, like --file-> -f

    --file /var/tmp/latest-bview
        MRT dump file

    --bind-ip 127.0.1.2
        IP to bind listener

    --bind-port 17900
        Port to use. NOTE that default is 17900 (so you dont need root), but
        bgp canonical port is actually 179 so you will need to change it (and
        give root or setcap) for it to work with non-soft router

    --local-ip 127.0.1.2
        IP for local side of connection - should be set to same as bind IP

    --local-as 65002
        Local AS number

    --peer-ip 127.0.1.1
        Peer IP

    --peer-as
        Peer AS

    --help
        display full help

### Filtering

Currently it does only very basic stuff - it drops every announcement for network if same network was announced in previous message



### Building

    carton install
    carton exec ./mrt2bgp.pl


### Testing

set up [Bird](http://bird.network.cz/) instance with config :

    router id 10.205.0.1;
    protocol kernel {
        export none;   # Do not insert anything into kernel. This is only a test
    }
    # bird need to see device up before setting up direct session
    protocol device {
    }
    protocol bgp gobgp{
      local 10.205.0.1 as 65001;
      import all; # take what you can
      export none;# give nothing back
      neighbor 10.205.0.2 port 17900 as 65002;
    };


then add network (somedev can be bridge, dummy0, ethernet etc, just not LO, bird doesn't like to run eBGP over lo)

    # ip addr add 10.205.0.1/24 dev somedev
    # ip addr add 10.205.0.1/24 dev somedev


and run it:

    # carton exec -- ./mrt-import.pl  --local-ip 10.205.0.2 --bind-ip 10.205.0.2 --peer-ip 10.205.0.1
