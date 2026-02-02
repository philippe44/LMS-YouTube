#! /bin/bash

rsync -avz --delete \
  --chown=squeezeboxserver:nogroup \
  plugin/ root@lms:/var/lib/squeezeboxserver/Plugins/YouTube/

