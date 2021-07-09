include_recipe "java"

group node['hops']['group'] do
  gid node['hops']['group_id']
  action :create
  not_if "getent group #{node['hops']['group']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

user node['hadoop_spark']['user'] do
  gid node['hops']['group']
  action :create
  system true
  shell "/bin/false"
  not_if "getent passwd #{node['hadoop_spark']['user']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

group node['hops']['group'] do
  action :modify
  members ["#{node['hadoop_spark']['user']}"]
  append true
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

directory node['hadoop_spark']['dir']  do
  owner "root"
  group node['hops']['group']
  mode "755"
  action :create
  not_if { File.directory?("#{node['hadoop_spark']['dir']}") }
end

package_url = "#{node['hadoop_spark']['url']}"
base_package_filename = File.basename(package_url)
cached_package_filename = "#{Chef::Config['file_cache_path']}/#{base_package_filename}"

remote_file cached_package_filename do
  source package_url
  owner "root"
  mode "0644"
  action :create_if_missing
end

spark_down = "#{node['hadoop_spark']['home']}/.hadoop_spark.extracted_#{node['hadoop_spark']['version']}"

# Extract Spark
bash 'extract_hadoop_spark' do
    user "root"
    code <<-EOH
       set -e
       rm -rf #{node['hadoop_spark']['base_dir']}
       tar -xf #{cached_package_filename} -C #{node['hadoop_spark']['dir']}
       chown -R #{node['hadoop_spark']['user']}:#{node['hops']['group']} #{node['hadoop_spark']['dir']}/spark*
       chmod -R 755 #{node['hadoop_spark']['dir']}/spark*
       touch #{spark_down}
    EOH
    not_if { ::File.exists?( spark_down ) }
end

link node['hadoop_spark']['base_dir'] do
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  to node['hadoop_spark']['home']
end

directory node['data']['dir'] do
  owner 'root'
  group 'root'
  mode '0775'
  action :create
  not_if { ::File.directory?(node['data']['dir']) }
end

directory node['hadoop_spark']['data_volume']['logs_dir'] do
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode '0770'
  recursive true
end

bash 'Move Spark logs to data volume' do
  user 'root'
  code <<-EOH
    set -e
    mv -f #{node['hadoop_spark']['logs_dir']}/* #{node['hadoop_spark']['data_volume']['logs_dir']}
    rm -rf #{node['hadoop_spark']['logs_dir']}
  EOH
  only_if { conda_helpers.is_upgrade }
  only_if { File.directory?(node['hadoop_spark']['logs_dir'])}
  not_if { File.symlink?(node['hadoop_spark']['logs_dir'])}
end

link node['hadoop_spark']['logs_dir'] do
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode '0770'
  to node['hadoop_spark']['data_volume']['logs_dir']
end

# The following dependencies are required to run spark-sql with parquet and orc. We install them here so that users don't have to do it from their notebooks/jobs
# https://mvnrepository.com/artifact/org.spark-project.hive/hive-exec/1.2.1.spark2
# http://central.maven.org/maven2/org/iq80/snappy/snappy/0.4/
# To make sure that all the custom jars that do not come with the Spark distribution are correctly updated
# during installation/upgrades, we create a separate directory which is cleaned up every time we run this recipe.
directory node['hadoop_spark']['hopsworks_jars'] do
  recursive true
  action :delete
  only_if { ::Dir.exist?(node['hadoop_spark']['hopsworks_jars']) }
end

directory node['hadoop_spark']['hopsworks_jars'] do
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode "0755"
  action :create
end

# We create a symlink from within spark/jars that points to spark/hopsworks-jars so that all the custom libraries
# are transparently available to the spark applications without the need of fixing the classpaths.
link "#{node['hadoop_spark']['home']}/jars/hopsworks-jars" do
  to node['hadoop_spark']['hopsworks_jars']
  link_type :symbolic
end

sql_dep = [
  "parquet-encoding-#{node['hadoop_spark']['parquet_version']}.jar",
  "parquet-common-#{node['hadoop_spark']['parquet_version']}.jar",
  "parquet-hadoop-#{node['hadoop_spark']['parquet_version']}.jar",
  "parquet-jackson-#{node['hadoop_spark']['parquet_version']}.jar",
  "parquet-column-#{node['hadoop_spark']['parquet_version']}.jar",
  "parquet-format-#{node['hadoop_spark']['parquet_format_version']}.jar",
  "snappy-#{node['hadoop_spark']['snappy_version']}.jar",
  "spark-avro_#{node['hadoop_spark']['spark_avro_version']}.jar",
  "spark-tensorflow-connector_#{node['hadoop_spark']['tf_spark_connector_version']}.jar",
  "spark-tfrecord_#{node['hadoop_spark']['spark_tfrecord_version']}.jar",
  "delta-core_#{node['hadoop_spark']['databricks_delta_version']}.jar",
  "spark-metrics_#{node['hadoop_spark']['spark-metrics_version']}.jar",
  "simpleclient-#{node['hadoop_spark']['simpleclient_version']}.jar",
  "simpleclient_common-#{node['hadoop_spark']['simpleclient_version']}.jar",
  "simpleclient_dropwizard-#{node['hadoop_spark']['simpleclient_version']}.jar",
  "simpleclient_pushgateway-#{node['hadoop_spark']['simpleclient_version']}.jar",
  "metrics-core-#{node['hadoop_spark']['metrics-core_version']}.jar",
  "elasticsearch-spark-#{node['hadoop_spark']['elastic_connector_version']}.jar",
  "spark-snowflake_#{node['hadoop_spark']['spark-snowflake_version']}.jar",
  "snowflake-jdbc-#{node['hadoop_spark']['snowflake-jdbc_version']}.jar"
]

for f in sql_dep do
  remote_file "#{node['hadoop_spark']['hopsworks_jars']}/#{f}" do
    source "#{node['hadoop_spark']['spark_sql_dependencies_url']}/#{f}"
    owner node['hadoop_spark']['user']
    group node['hops']['group']
    mode "0644"
    action :create_if_missing
  end
end

other_dependencies = [
  node['hadoop_spark']['hudi_bundle_url'],
  node['hadoop_spark']['mysql_driver'],
  node['hadoop_spark']['hopsutil']['url'],
  node['hadoop_spark']['hsfs']['url'],
]

for dep in other_dependencies do
  file_name = File.basename(dep)
  remote_file "#{node['hadoop_spark']['hopsworks_jars']}/#{file_name}" do
    source dep 
    owner node['hadoop_spark']['user']
    group node['hops']['group']
    mode "0644"
    action :create
  end
end

template"#{node['hadoop_spark']['conf_dir']}/log4j.properties" do
  source "app.log4j.properties.erb"
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode 0650
end

template"#{node['hadoop_spark']['conf_dir']}/yarnclient-driver-log4j.properties" do
  source "yarnclient-driver-log4j.properties.erb"
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode 0655
end

template"#{node['hadoop_spark']['conf_dir']}/executor-log4j.properties" do
  source "executor-log4j.properties.erb"
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode 0655
end

template"#{node['hadoop_spark']['home']}/conf/spark-env.sh" do
  source "spark-env.sh.erb"
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode 0655
end

template"#{node['hadoop_spark']['home']}/bin/getGpusResources.sh" do
  source "getGpusResources.sh.erb"
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode 0555
end

template"#{node['hadoop_spark']['home']}/conf/spark-blacklisted-properties.txt" do
  source "spark-blacklisted-properties.txt.erb"
  owner node['hadoop_spark']['user']
  group node['hops']['group']
  mode 0655
end

magic_shell_environment 'SPARK_HOME' do
  value node['hadoop_spark']['base_dir']
end
