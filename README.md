# LMS-YouTube

Fork of [Triode's YouTube plugin for API V3](https://forums.slimdevices.com/showthread.php?87731-Announce-YouTube-Plugin&p=631449&viewfull=1#post631449) for [Logitech Media Server](https://github.com/Logitech/slimserver).
See the support thread here: [forums.slimdevices.com/showthread.php?105840-ANNOUNCE-YouTube-Plugin-(API-v3)](http://forums.slimdevices.com/showthread.php?105840-ANNOUNCE-YouTube-Plugin-(API-v3)&p=857414&viewfull=1#post857414).

## Common pitfalls

### SSL issues

This plugin *requires* SSL so make sure it's installed on your LMS server. Not a problem for Windows, OSX, most Linux x86, Raspberry pi, Cubie, Odroid and others that use a Debian-based, but can be problematic with some NAS.
Other than that, Perl must have SSL support enabled, which again is available in all recent distribution and LMS versions (I think). But in case of problem and for Debian-ish Linux, you can try

```bash
sudo apt install libio-socket-ssl-perl libnet-ssleay-perl
```

at any command prompt.

### Country for Categories

Keep in mind that `UK` is *not* a region code, but `GB` is.
