#!/bin/bash
cd $PWD
proxy_status=$(curl -iL http://localhost/ping 2>/dev/null | head -n 1 | cut -d$' ' -f2)
conf_path="volumes/conf.d"

## selfhelp
if [[ $proxy_status != 200 ]]; then
  git add . && git stash 
  git pull
  systemctl restart aio.service
  ## notification
  exit 1
fi

##0-downtime update agent
pull_result=$(git pull | base64)
local_commit_hash=$(git rev-parse --short HEAD)

if [[ $pull_result != "QWxyZWFkeSB1cCB0byBkYXRlLgo=" ]]; then
  echo "NEW COMMIT $local_commit_hash `date`" >> /var/log/git.log
  docker-compose --profile spare-agent up -d
  sleep 3 
  mv $conf_path/upstream.conf $conf_path/upstream && mv $conf_path/upstream-spare $conf_path/upstream-spare.conf && docker exec proxy-nginx nginx -s reload
  docker-compose --profile main up -d 
  sleep 3
  mv $conf_path/upstream $conf_path/upstream.conf && mv $conf_path/upstream-spare.conf $conf_path/upstream-spare && docker exec proxy-nginx nginx -s reload
  sleep 3
  docker-compose --profile spare-agent down
  echo "APP RESTARTED `date`" >> /var/log/git.log
  echo "SUCCESS UPDATE $local_commit_hash `date`" >> /var/log/git.log
fi