require 'cfndsl'
require_relative '../../ext/helper'




CloudFormation do
  # Template metadata
  AWSTemplateFormatVersion "2010-09-09"
  Description "#{application_name} - ECS Service - #{service} v#{cf_version}"

  # Parameters
  Parameter("EnvironmentType"){ Type 'String' }
  Parameter("EnvironmentName"){ Type 'String' }
  Parameter("VPC"){ Type 'String' }
  Parameter("StackOctet") { Type 'String' }
  Parameter("SecurityGroupOps") { Type 'String' }
  Parameter("SecurityGroupDev") { Type 'String' }
  Parameter("SecurityGroupBackplane") { Type 'String' }

  Parameter('TestECSCluster'){ Type 'String' }
  Parameter('TestSlaveECSCluster'){ Type 'String' }
  Parameter('TestLogGroup') { Type 'String' }
  Parameter('TestECSENIPrivateIpAddress') { Type 'String' }


  listener_parameters(loadbalancers)

  maximum_availability_zones.times do |az|
    Parameter("RouteTablePrivate#{az}") do
      Type 'String'
      Default false
    end
    Parameter("SubnetPublic#{az}") do
      Type 'String'
      Default false
    end
  end

  Mapping('EnvironmentType', EnvironmentType)
  Mapping('AccountId', AccountId)
  Mapping('locust', locust)

  mapped_availability_zones.each do |account, map|
    Mapping(account, map)
  end

  az_conditions
  az_count

  Resource("ECSRole") {
    Type 'AWS::IAM::Role'
    Property('AssumeRolePolicyDocument', {
      Statement: [
        Effect: 'Allow',
        Principal: { Service: [ 'ecs.amazonaws.com' ] },
        Action: [ 'sts:AssumeRole' ]
      ]
    })
    Property('Path','/')
    Property('Policies', Policies.new.get_policies('services'))
  }

  definitions, mount_pounts, volumes, ports = Array.new(4){[]}



  tasks[service].each do |task|
    env_vars = []
    definition = Hash.new

    definition.merge!({
      Name: task['name'],
      Memory: task['memory'],
      Cpu: task['cpu'],
      Image: FnJoin("", [ "#{ecr_repo}", "#{task['image']}" ]),
      LogConfiguration: {
        LogDriver: 'awslogs',
        Options: {
          'awslogs-group' => Ref('TestLogGroup'),
          "awslogs-region" => Ref("AWS::Region"),
          "awslogs-stream-prefix" => task['name']
        }
      }
    })

    essential = (task.has_key?('Essential') ? task['Essential'] : true)
    definition.merge!({Essential: essential})

    # add docker volumes
    if !(task['volumes'].nil?)
      task['volumes'].each do |volume|
        mount_pounts << { ContainerPath: volume['container_path'], SourceVolume: volume['name'], ReadOnly: (volume.key?('read_only') ? true : false) }
        volumes << { Name: volume['name'], Host: { SourcePath: volume['source_path'] } }
      end
      definition.merge!({MountPoints: mount_pounts })
    end

    if task.has_key?('env_vars')
      task['env_vars'].each do |env_var|
        env_vars << env_var
      end
    end

    definition.merge!({Environment: env_vars }) if env_vars.any?
    definition.merge!({PortMappings: task['ports'].map{|x| {ContainerPort: x['ContainerPort']}}}) if task.has_key?('ports')
    definition.merge!({Links: task['links']}) if task.has_key?('links')
    definitions << definition
  end

  Resource('Task') {
    Type "AWS::ECS::TaskDefinition"
    Property('ContainerDefinitions', definitions)
    Property('NetworkMode', 'host') if service == 'locustmaster'
    Property('Volumes', volumes) if volumes.any?
  }

  service_loadbalancer = []

  tasks[service].each do |task|
    next unless task.has_key?('ports')
    task['ports'].each do |forward|
      if forward['targetgroup'] == true && forward.has_key?('ContainerPort')
        create_target_group(service,targetgroups[service])
        puts targetgroups[service]
        create_listener_rule(service,targetgroups[service])
        service_loadbalancer << { ContainerName: task['name'], ContainerPort: forward['ContainerPort'], TargetGroupArn: ref_target_group(service) }
      elsif forward['targetgroup'].is_a? String
        service_loadbalancer << { ContainerName: task['name'], ContainerPort: forward['ContainerPort'], TargetGroupArn: ref_default_target_group(forward['targetgroup']) }
      elsif forward['loadbalancer'] == true
        # TODO: create_classic_elb(name)
        # service_loadbalancer << { ContainerName: service, ContainerPort: task[service]['port'], LoadBalancer: ref_classic_elb(service) }
      end
    end
  end

  Resource('Service') {
    Type 'AWS::ECS::Service'
    Property('Cluster', Ref('TestECSCluster')) if service == 'locustmaster'
    Property('Cluster', Ref('TestSlaveECSCluster')) if service == 'locustslave'
    Property('DesiredCount', 1)
    Property('DeploymentConfiguration', {
      MinimumHealthyPercent: 0,
      MaximumPercent: 100
    })
    Property('TaskDefinition', Ref('Task'))
    if service_loadbalancer.any?
     Property('Role', Ref('ECSRole'))
     Property('LoadBalancers', service_loadbalancer)
    end
  }

end
