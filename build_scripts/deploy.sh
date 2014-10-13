#!/bin/bash -xe


. ${env_file:-/var/lib/jenkins/cloud.${env}.env}

if ! [ -e venv ]
then
    virtualenv venv
    . venv/bin/activate
    pip install -e git+https://github.com/JioCloud/python-jiocloud#egg=jiocloud
    deactivate
fi

. venv/bin/activate

# this is here to allow a user to override the command used for
# the timeout function just incase it happens to be gtimeout
timeout=${timeout_command:-timeout}

if [ -z "${etcd_discovery_token}" ]
then
    etcd_discovery_token=$(python -m jiocloud.orchestrate new_discovery_token)
fi

if [ -z "${consul_discovery_token}" ]
then
    consul_discovery_token=$(curl http://consuldiscovery.linux2go.dk/new)
fi

if [ -z "${env}" ]
then
    env='acceptance'
fi

cat <<EOF >userdata.txt
#!/bin/bash
release="\$(lsb_release -cs)"
if [ -n "${env_http_proxy}" ]
then
	export http_proxy=${env_http_proxy}
	echo http_proxy="'${env_http_proxy}'" >> /etc/environment
fi
if [ -n "${env_https_proxy}" ]
then
	export https_proxy=${env_https_proxy}
	export ETCD_DISCOVERY_PROXY=${env_https_proxy}
	echo ETCD_DISCOVERY_PROXY="'${env_https_proxy}'" >> /etc/environment
	echo https_proxy="'${env_https_proxy}'" >> /etc/environment
fi
wget -O puppet.deb http://apt.puppetlabs.com/puppetlabs-release-\${release}.deb
wget -O jiocloud.deb http://jiocloud.rustedhalo.com/ubuntu/jiocloud-apt-\${release}.deb
dpkg -i puppet.deb jiocloud.deb
apt-get update
apt-get install -y puppet software-properties-common puppet-jiocloud
if [ -n "${puppet_modules_source_repo}" ]; then
  apt-get install -y git
  git clone ${puppet_modules_source_repo} /tmp/rjil
  if [ -n "${puppet_modules_source_branch}" ]; then
    pushd /tmp/rjil
    git checkout ${puppet_modules_source_branch}
    popd
  fi
  if [ -n "${pull_request_id}" ]; then
    pushd /tmp/rjil
    git fetch origin pull/${pull_request_id}/head:test_${pull_request_id}
    git config user.email "testuser@localhost.com"
    git config user.name "Test User"
    git merge -m 'Merging Pull Request' test_${pull_request_id}
    popd
  fi
  gem install librarian-puppet-simple --no-ri --no-rdoc;
  mkdir -p /etc/puppet/manifests.overrides
  cp /tmp/rjil/site.pp /etc/puppet/manifests.overrides/
  mkdir -p /etc/puppet/hiera
  cp /tmp/rjil/hiera/hiera.yaml /etc/puppet
  cp -Rvf /tmp/rjil/hiera/data /etc/puppet/hiera
  mkdir -p /etc/puppet/modules.overrides/rjil
  cp -Rvf /tmp/rjil/* /etc/puppet/modules.overrides/rjil/
  librarian-puppet install --puppetfile=/tmp/rjil/Puppetfile --path=/etc/puppet/modules.overrides
  puppet apply -e "ini_setting { modulepath: path => \"/etc/puppet/puppet.conf\", section => main, setting => modulepath, value => \"/etc/puppet/modules.overrides:/etc/puppet/modules\" }"
  puppet apply -e "ini_setting { manifestdir: path => \"/etc/puppet/puppet.conf\", section => main, setting => manifestdir, value => \"/etc/puppet/manifests.overrides\" }"
fi
sudo mkdir -p /etc/facter/facts.d
echo 'etcd_discovery_token='${etcd_discovery_token} > /etc/facter/facts.d/etcd.txt
echo 'consul_discovery_token='${consul_discovery_token} > /etc/facter/facts.d/consul.txt
echo 'env='${env} > /etc/facter/facts.d/env.txt
puppet apply --debug -e "include rjil::jiocloud"
EOF

python -m jiocloud.apply_resources apply --key_name=${KEY_NAME:-soren} --project_tag=test${BUILD_NUMBER} environment/cloud.${env}.yaml userdata.txt

ip=$(python -m jiocloud.utils get_ip_of_node etcd1_test${BUILD_NUMBER})

$timeout 1200 bash -c "while ! python -m jiocloud.orchestrate --host ${ip} ping; do sleep 5; done"

$timeout 600 bash -c "while ! ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${ssh_user:-jenkins}@${ip} python -m jiocloud.orchestrate trigger_update ${BUILD_NUMBER}; do sleep 5; done"

$timeout 1200 bash -c "while ! python -m jiocloud.apply_resources list --project_tag=test${BUILD_NUMBER} environment/cloud.${env}.yaml | sed -e 's/_/-/g' | python -m jiocloud.orchestrate --host ${ip} verify_hosts ${BUILD_NUMBER} ; do sleep 5; done"
$timeout 900 bash -c "while ! python -m jiocloud.orchestrate --host ${ip} check_single_version -v ${BUILD_NUMBER} ; do sleep 5; done"
# make sure that there are not any failures
if ! python -m jiocloud.orchestrate --host ${ip} get_failures; then
  echo "Failures occurred"
fi
