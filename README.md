# LMS-YouTube

Fork of [Triode's YouTube plugin for API V3](https://forums.slimdevices.com/showthread.php?87731-Announce-YouTube-Plugin&p=631449&viewfull=1#post631449) for [Logitech Media Server](https://github.com/Logitech/slimserver).
See the support thread here: [forums.slimdevices.com/showthread.php?105840-ANNOUNCE-YouTube-Plugin-(API-v3)](http://forums.slimdevices.com/showthread.php?105840-ANNOUNCE-YouTube-Plugin-(API-v3)&p=857414&viewfull=1#post857414).

## How to setup

You *need* a YouTube API key, so either find somebody that gives you one or follow these steps

1. Goto https://console.developers.google.com using your gmail account
1. Click: `Create Project`
1. Name the project (i.e. `YouTube-API-Key-Project`) and leave `Organization` blank
1. Click `Create`
1. Once at your project dashboard, in the APIs box, click: Go to APIs Overview
1. In the APIs & Services Dashboard, click: `Enable APIs and Services`
1. In the API Library, search for "`youtube`" and click: `YouTube Data API v3`
1. In the `YouTube Data API v3` screen, click: `ENABLE`
1. In the `YouTube Data API v3` Overview, click: `CREATE CREDENTIALS`
1. Under "`Which API are you using?`" choose: `YouTube Data API v3`
1. Under "`Where will you be calling the API from?`" choose: `Web browser (Javascript)`
1. Under "`What data will you be accessing?`" choose: `Public data`
1. Then click "`What credentials do I need?`" button.
1. You should now see your API key. Copy it to your clipboard.
1. Click the link: "`Restrict key`"
1. Under "`API restrictions`" select `Restrict key`, and check "`YouTube Data API v3`"
1. Click `Save`
1. Return to the YouTube plugin and paste your key, making sure there are no preceding or trailing spaces in what you paste.

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
