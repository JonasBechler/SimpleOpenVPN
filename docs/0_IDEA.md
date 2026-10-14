my devices share the same vpn so i can access these devices from everywhere
i host a server which runs an openvpn server

the server has one task: run openvpn server securely


further requirements:
    auto secutiry updates
    only key auth for security over ssh
    i can easiliy log into the server over ssh and create new client certificates
    fixed ip per client
    good overview for mee chick client sits at which ip
    there should be 2 possibilities to access (each client should get 2 configs):
        over the default openvpn port, route only when needed
        over 443 tcp, route all throug the tunnel