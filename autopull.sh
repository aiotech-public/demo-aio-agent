#!/bin/bash
cd $PWD
# Health check: nginx answers on :80 (any HTTP code; 000 = no connection) and the agent container is running.
# Do not depend on a specific path/status code: the agent serves every path as a regular site request.
proxy_status=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost/healthcheck.yml 2>/dev/null)
agent_running=$(docker inspect -f '{{.State.Running}}' aio-agent 2>/dev/null)
conf_path="volumes/nginx/stream.d"

## selfhelp
if [[ -z "$proxy_status" || "$proxy_status" == "000" || "$agent_running" != "true" ]]; then
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
  mv $conf_path/regular.conf $conf_path/regular && mv $conf_path/spare $conf_path/spare.conf && docker exec proxy-nginx nginx -s reload
  docker-compose --profile main up -d 
  sleep 3
  mv $conf_path/regular $conf_path/regular.conf && mv $conf_path/spare.conf $conf_path/spare && docker exec proxy-nginx nginx -s reload
  sleep 3
  docker-compose --profile spare-agent down
  
  ## old image cleanup
  docker image prune -af --filter "until=168h" >> /var/log/aio-docker-prune.log 2>&1 || true 
  
  echo "APP RESTARTED `date`" >> /var/log/git.log
  echo "SUCCESS UPDATE $local_commit_hash `date`" >> /var/log/git.log
fi
