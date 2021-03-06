#!/bin/bash -x

################################################################################
# Script that is run on each EC2 instance on boot. It is passed in the EC2 user
# data, so should not exceed 16K in size after gzip compression.
#
# This script is executed by /etc/init.d/ec2-run-user-data, and output is
# logged to /var/log/messages.
################################################################################

################################################################################
# Initialize variables
################################################################################

exec > /var/log/user-data-file-out.log
exec 2> /var/log/user-data-file-err.log

# Substitute environment variables passed by the client
export %ENV%

REPO=${REPO:-cdh3b3}
HADOOP=hadoop-${HADOOP_VERSION:-0.20}
HADOOP_CONF_DIR=/etc/$HADOOP/conf.dist
SELF_HOST=`wget -q -O - http://169.254.169.254/latest/meta-data/public-hostname`

for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  nn)
    NN_HOST=$SELF_HOST
    ;;
  jt)
    JT_HOST=$SELF_HOST
    ;;
  esac
done

function register_auto_shutdown() {
  if [ ! -z "$AUTO_SHUTDOWN" ]; then
    shutdown -h +$AUTO_SHUTDOWN >/dev/null &
  fi
}

function update_repo() {
  if which dpkg &> /dev/null; then
    DISTRO=`lsb_release -s -c`
    cat > /etc/apt/sources.list.d/cloudera.list <<EOF
deb http://archive.cloudera.com/debian $DISTRO-$REPO contrib
deb-src http://archive.cloudera.com/debian $DISTRO-$REPO contrib
EOF
    curl -s http://archive.cloudera.com/debian/archive.key | apt-key add -
    # Enable multiverse
    # TODO: check that it is not already enabled
    sed -i -e 's/universe$/universe multiverse/' /etc/apt/sources.list
    cat > /etc/apt/sources.list.d/canonical.com.list <<EOF
deb http://archive.canonical.com/ubuntu $DISTRO partner
deb-src http://archive.canonical.com/ubuntu $DISTRO partner
EOF
    sudo apt-get update
  elif which rpm &> /dev/null; then
    rm -f /etc/yum.repos.d/cloudera.repo
    REPO_NUMBER=`echo $REPO | sed -e 's/cdh\([0-9][0-9]*\)/\1/'`
    cat > /etc/yum.repos.d/cloudera-$REPO.repo <<EOF
[cloudera-$REPO]
name=Cloudera's Distribution for Hadoop ($REPO)
mirrorlist=http://archive.cloudera.com/redhat/cdh/$REPO_NUMBER/mirrors
gpgkey = http://archive.cloudera.com/redhat/cdh/RPM-GPG-KEY-cloudera
gpgcheck = 0
EOF
    yum update -y yum
  fi
}

# Install a list of packages on debian or redhat as appropriate
function install_packages() {
  if which dpkg &> /dev/null; then
    apt-get update
    apt-get -y install $@
  elif which rpm &> /dev/null; then
    yum install -y $@
  else
    echo "No package manager found."
  fi
}

# Install any user packages specified in the USER_PACKAGES environment variable
function install_user_packages() {
  if [ ! -z "$USER_PACKAGES" ]; then
    install_packages $USER_PACKAGES
  fi
}

# Install Hadoop packages and dependencies
function install_hadoop() {
  if which dpkg &> /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update

    # Install Java
    echo 'sun-java6-bin   shared/accepted-sun-dlj-v1-1    boolean true
sun-java6-jdk   shared/accepted-sun-dlj-v1-1    boolean true
sun-java6-jre   shared/accepted-sun-dlj-v1-1    boolean true
sun-java6-jre   sun-java6-jre/stopthread        boolean true
sun-java6-jre   sun-java6-jre/jcepolicy note
sun-java6-bin   shared/present-sun-dlj-v1-1     note
sun-java6-jdk   shared/present-sun-dlj-v1-1     note
sun-java6-jre   shared/present-sun-dlj-v1-1     note
' | debconf-set-selections
    ENDALL='6.22-0ubuntu1~10.04_all.deb'
    if [ `uname -m` == x86_64 ]; then
        ENDPLAT='6.22-0ubuntu1~10.04_amd64.deb'
    else
        ENDPLAT='6.22-0ubuntu1~10.04_i386.deb'
    fi
    apt-get -y install java-common locales unixodbc
    ROOT=http://cs61c-data.s3.amazonaws.com/sun-java6-jdk-mirror
    DEB="sun-java6-bin_$ENDPLAT sun-java6-jdk_$ENDPLAT sun-java6-jre_$ENDALL"
    for deb in $DEB; do
        wget $ROOT/$deb
    done
    dpkg -i $DEB
    # apt-get -y install sun-java6-jdk
    echo "export JAVA_HOME=/usr/lib/jvm/java-6-sun" >> /etc/profile
    export JAVA_HOME=/usr/lib/jvm/java-6-sun
    java -version
    
    apt-get -y install rsync
    apt-get -y install $HADOOP
    cp -r /etc/$HADOOP/conf.empty $HADOOP_CONF_DIR
    update-alternatives --install /etc/$HADOOP/conf $HADOOP-conf $HADOOP_CONF_DIR 90
    apt-get -y install hadoop-pig${PIG_VERSION:+-${PIG_VERSION}}
    apt-get -y install hadoop-hive${HIVE_VERSION:+-${HIVE_VERSION}}
  elif which rpm &> /dev/null; then
    yum install -y $HADOOP
    cp -r /etc/$HADOOP/conf.empty $HADOOP_CONF_DIR
    if [ ! -e /etc/alternatives/$HADOOP-conf ]; then # CDH1 RPMs use a different alternatives name
      conf_alternatives_name=hadoop
    else
      conf_alternatives_name=$HADOOP-conf
    fi
    alternatives --install /etc/$HADOOP/conf $conf_alternatives_name $HADOOP_CONF_DIR 90
    yum install -y hadoop-pig${PIG_VERSION:+-${PIG_VERSION}}
    yum install -y hadoop-hive${HIVE_VERSION:+-${HIVE_VERSION}}
  fi
}

function prep_disk() {
  mount=$1
  device=$2
  automount=${3:-false}

  echo "warning: ERASING CONTENTS OF $device"
  mkfs.xfs -f $device
  if [ ! -e $mount ]; then
    mkdir $mount
  fi
  mount -o defaults,noatime $device $mount
  if $automount ; then
    echo "$device $mount xfs defaults,noatime 0 0" >> /etc/fstab
  fi
}

function wait_for_mount {
  mount=$1
  device=$2

  mkdir $mount

  i=1
  echo "Attempting to mount $device"
  while true ; do
    sleep 10
    echo -n "$i "
    i=$[$i+1]
    mount -o defaults,noatime $device $mount || continue
    echo " Mounted."
    break;
  done
}

function make_hadoop_dirs {
  for mount in "$@"; do
    if [ ! -e $mount/hadoop ]; then
      mkdir -p $mount/hadoop
      chown root:hadoop $mount/hadoop
      chmod -R g+rwX $mount/hadoop
    fi
  done
}

# Configure Hadoop by setting up disks and site file
function configure_hadoop() {

  install_packages xfsprogs # needed for XFS

  INSTANCE_TYPE=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-type`

  if [ -n "$EBS_MAPPINGS" ]; then
    # EBS_MAPPINGS is like "/ebs1,/dev/sdj;/ebs2,/dev/sdk"
    DFS_NAME_DIR=''
    FS_CHECKPOINT_DIR=''
    DFS_DATA_DIR=''
    for mapping in $(echo "$EBS_MAPPINGS" | tr ";" "\n"); do
      # Split on the comma (see "Parameter Expansion" in the bash man page)
      mount=${mapping%,*}
      device=${mapping#*,}
      wait_for_mount $mount $device
      DFS_NAME_DIR=${DFS_NAME_DIR},"$mount/hadoop/hdfs/name"
      FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR},"$mount/hadoop/hdfs/secondary"
      DFS_DATA_DIR=${DFS_DATA_DIR},"$mount/hadoop/hdfs/data"
      FIRST_MOUNT=${FIRST_MOUNT-$mount}
      make_hadoop_dirs $mount
    done
    # Remove leading commas
    DFS_NAME_DIR=${DFS_NAME_DIR#?}
    FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR#?}
    DFS_DATA_DIR=${DFS_DATA_DIR#?}

    DFS_REPLICATION=3 # EBS is internally replicated, but we also use HDFS replication for safety
  else
    case $INSTANCE_TYPE in
    m1.xlarge|c1.xlarge)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data,/mnt3/hadoop/hdfs/data,/mnt4/hadoop/hdfs/data
      ;;
    m1.large)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data
      ;;
    *)
      # "m1.small" or "c1.medium"
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data
      ;;
    esac
    FIRST_MOUNT=/mnt
    DFS_REPLICATION=3
  fi

  case $INSTANCE_TYPE in
  m1.xlarge|c1.xlarge)
    prep_disk /mnt2 /dev/sdc true &
    disk2_pid=$!
    prep_disk /mnt3 /dev/sdd true &
    disk3_pid=$!
    prep_disk /mnt4 /dev/sde true &
    disk4_pid=$!
    wait $disk2_pid $disk3_pid $disk4_pid
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local,/mnt3/hadoop/mapred/local,/mnt4/hadoop/mapred/local
    MAX_MAP_TASKS=8
    MAX_REDUCE_TASKS=4
    CHILD_OPTS=-Xmx680m
    CHILD_ULIMIT=1392640
    ;;
  m1.large)
    prep_disk /mnt2 /dev/sdc true
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx1024m
    CHILD_ULIMIT=2097152
    ;;
  c1.medium)
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    ;;
  *)
    # "m1.small"
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=2
    MAX_REDUCE_TASKS=1
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    ;;
  esac

  make_hadoop_dirs `ls -d /mnt*`

  # Create tmp directory
  mkdir /mnt/tmp
  chmod a+rwxt /mnt/tmp

  ##############################################################################
  # Modify this section to customize your Hadoop cluster.
  ##############################################################################
  cat > $HADOOP_CONF_DIR/hadoop-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>dfs.block.size</name>
  <value>134217728</value>
  <final>true</final>
</property>
<property>
  <name>dfs.data.dir</name>
  <value>$DFS_DATA_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.du.reserved</name>
  <value>1073741824</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.handler.count</name>
  <value>3</value>
  <final>true</final>
</property>
<!--property>
  <name>dfs.hosts</name>
  <value>$HADOOP_CONF_DIR/dfs.hosts</value>
  <final>true</final>
</property-->
<!--property>
  <name>dfs.hosts.exclude</name>
  <value>$HADOOP_CONF_DIR/dfs.hosts.exclude</value>
  <final>true</final>
</property-->
<property>
  <name>dfs.name.dir</name>
  <value>$DFS_NAME_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.namenode.handler.count</name>
  <value>5</value>
  <final>true</final>
</property>
<property>
  <name>dfs.permissions</name>
  <value>true</value>
  <final>true</final>
</property>
<property>
  <name>dfs.replication</name>
  <value>$DFS_REPLICATION</value>
</property>
<property>
  <name>fs.checkpoint.dir</name>
  <value>$FS_CHECKPOINT_DIR</value>
  <final>true</final>
</property>
<property>
  <name>fs.default.name</name>
  <value>hdfs://$NN_HOST:8020/</value>
</property>
<property>
  <name>fs.trash.interval</name>
  <value>1440</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.tmp.dir</name>
  <value>/mnt/tmp/hadoop-\${user.name}</value>
  <final>true</final>
</property>
<property>
  <name>io.file.buffer.size</name>
  <value>65536</value>
</property>
<property>
  <name>mapred.child.java.opts</name>
  <value>$CHILD_OPTS</value>
</property>
<property>
  <name>mapred.child.ulimit</name>
  <value>$CHILD_ULIMIT</value>
  <final>true</final>
</property>
<property>
  <name>mapred.job.tracker</name>
  <value>$JT_HOST:8021</value>
</property>
<property>
  <name>mapred.job.tracker.handler.count</name>
  <value>5</value>
  <final>true</final>
</property>
<property>
  <name>mapred.local.dir</name>
  <value>$MAPRED_LOCAL_DIR</value>
  <final>true</final>
</property>
<property>
  <name>mapred.map.tasks.speculative.execution</name>
  <value>true</value>
</property>
<property>
  <name>mapred.reduce.parallel.copies</name>
  <value>10</value>
</property>
<property>
  <name>mapred.reduce.tasks</name>
  <value>10</value>
</property>
<property>
  <name>mapred.reduce.tasks.speculative.execution</name>
  <value>false</value>
</property>
<property>
  <name>mapred.submit.replication</name>
  <value>10</value>
</property>
<property>
  <name>mapred.system.dir</name>
  <value>/user/mapred/hadoop/system/mapred</value>
</property>
<property>
  <name>mapred.tasktracker.map.tasks.maximum</name>
  <value>$MAX_MAP_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>mapred.tasktracker.reduce.tasks.maximum</name>
  <value>$MAX_REDUCE_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>tasktracker.http.threads</name>
  <value>46</value>
  <final>true</final>
</property>
<property>
  <name>mapred.jobtracker.taskScheduler</name>
  <value>org.apache.hadoop.mapred.FairScheduler</value>
</property>
<property>
  <name>mapred.fairscheduler.allocation.file</name>
  <value>$HADOOP_CONF_DIR/fairscheduler.xml</value>
</property>
<property>
  <name>mapred.compress.map.output</name>
  <value>true</value>
</property>
<property>
  <name>mapred.output.compression.type</name>
  <value>BLOCK</value>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.default</name>
  <value>org.apache.hadoop.net.StandardSocketFactory</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.ClientProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.JobSubmissionProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>io.compression.codecs</name>
  <value>org.apache.hadoop.io.compress.DefaultCodec,org.apache.hadoop.io.compress.GzipCodec</value>
</property>
<property>
  <name>fs.s3.awsAccessKeyId</name>
  <value>$AWS_ACCESS_KEY_ID</value>
</property>
<property>
  <name>fs.s3.awsSecretAccessKey</name>
  <value>$AWS_SECRET_ACCESS_KEY</value>
</property>
<property>
  <name>fs.s3n.awsAccessKeyId</name>
  <value>$AWS_ACCESS_KEY_ID</value>
</property>
<property>
  <name>fs.s3n.awsSecretAccessKey</name>
  <value>$AWS_SECRET_ACCESS_KEY</value>
</property>
</configuration>
EOF

  cat > $HADOOP_CONF_DIR/fairscheduler.xml <<EOF
<?xml version="1.0"?>
<allocations>
</allocations>
EOF

  # Keep PID files in a non-temporary directory
  sed -i -e "s|# export HADOOP_PID_DIR=.*|export HADOOP_PID_DIR=/var/run/hadoop|" \
    $HADOOP_CONF_DIR/hadoop-env.sh
  mkdir -p /var/run/hadoop
  chown -R root:hadoop /var/run/hadoop
  chmod -R g+rwX /var/run/hadoop

  # Set SSH options within the cluster
  sed -i -e 's|# export HADOOP_SSH_OPTS=.*|export HADOOP_SSH_OPTS="-o StrictHostKeyChecking=no"|' \
    $HADOOP_CONF_DIR/hadoop-env.sh

  # Hadoop logs should be on the /mnt partition
  rm -rf /var/log/hadoop
  mkdir /mnt/hadoop/logs
  chown -R root:hadoop /mnt/hadoop/logs
  chmod -R g+rwX /mnt/hadoop/logs
  ln -s /mnt/hadoop/logs /var/log/hadoop
  ln -s /mnt/hadoop/logs /var/log/hadoop-0.20
  chown -R root:hadoop /var/log/hadoop
  chmod -R g+rwX /var/run/hadoop
}

# Sets up small website on cluster.
function setup_web() {

  if which dpkg &> /dev/null; then
    apt-get -y install thttpd
    sed -i -e "s|ENABLED=no|ENABLED=yes|" /etc/default/thttpd
    WWW_BASE=/var/www
  elif which rpm &> /dev/null; then
    yum install -y thttpd
    chkconfig --add thttpd
    WWW_BASE=/var/www/thttpd/html
  fi

  cat > $WWW_BASE/index.html << END
<html>
<head>
<title>Hadoop EC2 Cluster</title>
</head>
<body>
<h1>Hadoop EC2 Cluster</h1>
To browse the cluster you need to have a proxy configured.
Start the proxy with <tt>eval `hadoop-ec2 proxy &lt;cluster_name&gt;`</tt>,
and point your browser to
<a href="http://cloudera-public.s3.amazonaws.com/ec2/proxy.pac">this Proxy
Auto-Configuration (PAC)</a> file. You may find using
<a href="https://addons.mozilla.org/en-US/firefox/addon/2464">FoxyProxy</a>
useful for managing PAC files.
<ul>
<li><a href="http://$NN_HOST:50070/">NameNode</a>
<li><a href="http://$JT_HOST:50030/">JobTracker</a>
</ul>
</body>
</html>
END

  service thttpd start

}

function start_namenode() {
  if which dpkg &> /dev/null; then
    AS_HDFS="su -s /bin/bash - hdfs -c"
    AS_MAPRED="su -s /bin/bash - mapred -c"
    # Format HDFS
    [ ! -e $FIRST_MOUNT/hadoop/hdfs ] && $AS_HDFS "$HADOOP namenode -format"
    apt-get -y install $HADOOP-namenode
    apt-get -y install $HADOOP-secondarynamenode
  elif which rpm &> /dev/null; then
    AS_HADOOP="/sbin/runuser -s /bin/bash - hadoop -c"
    # Format HDFS
    [ ! -e $FIRST_MOUNT/hadoop/hdfs ] && $AS_HADOOP "$HADOOP namenode -format"
    chkconfig --add $HADOOP-namenode
    chkconfig --add $HADOOP-secondarynamenode
  fi

  service $HADOOP-namenode start
  service $HADOOP-secondarynamenode start

  $AS_HDFS "$HADOOP dfsadmin -safemode wait"
  $AS_HDFS "/usr/bin/$HADOOP fs -mkdir /user"
  # The following is questionable, as it allows a user to delete another user
  # It's needed to allow users to create their own user directories
  $AS_HDFS "/usr/bin/$HADOOP fs -chmod +w /user"

  # Create temporary directory for Pig and Hive in HDFS
  $AS_HDFS "/usr/bin/$HADOOP fs -mkdir /tmp"
  $AS_HDFS "/usr/bin/$HADOOP fs -chmod +w /tmp"
  $AS_HDFS "/usr/bin/$HADOOP fs -mkdir /user/hive/warehouse"
  $AS_HDFS "/usr/bin/$HADOOP fs -chmod +w /user/hive/warehouse"

  # No permissions problems, please.
  $AS_HDFS "/usr/bin/$HADOOP fs -chmod +w /"
}

function start_daemon() {
  daemon=$1
  if which dpkg &> /dev/null; then
    apt-get -y install $HADOOP-$daemon
  elif which rpm &> /dev/null; then
    yum install -y $HADOOP-$daemon
    chkconfig --add $HADOOP-$daemon
  fi
  service $HADOOP-$daemon start
}

register_auto_shutdown
update_repo
install_user_packages
install_hadoop
configure_hadoop

for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  nn)
    setup_web
    start_namenode
    ;;
  snn)
    start_daemon secondarynamenode
    ;;
  jt)
    start_daemon jobtracker
    ;;
  dn)
    start_daemon datanode
    ;;
  tt)
    start_daemon tasktracker
    ;;
  esac
done

# Enable root login
# See http://alestic.com/2009/04/ubuntu-ec2-sudo-ssh-rsync
if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
  cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
fi

