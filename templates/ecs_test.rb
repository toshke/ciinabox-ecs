require 'cfndsl'
require_relative '../ext/helper.rb'

CloudFormation do
  AWSTemplateFormatVersion '2010-09-09'
  Description "ciinabox - ECS Loadtesting v#{ciinabox_version}"

  Parameter("EnvironmentType"){ Type 'String' }
  Parameter("EnvironmentName"){ Type 'String' }
  Parameter("VPC"){ Type 'String' }
  Parameter("StackOctet") { Type 'String' }
  Parameter("SecurityGroupBackplane"){ Type 'String' }
  Parameter("SecurityGroupOps"){ Type 'String' }
  Parameter("SecurityGroupDev"){ Type 'String' }
  Parameter("CostCenter"){ Type 'String' }

  # Global mappings
  Mapping('EnvironmentType', Mappings['EnvironmentType'])
  Mapping('TestAMI', ecsAMI)

  availability_zones.each do |az|
    Resource("SubnetPrivate#{az}") {
      Type 'AWS::EC2::Subnet'
      Property('VpcId', Ref('VPC'))
      Property('CidrBlock', FnJoin("", [FnFindInMap('EnvironmentType', 'ciinabox', 'NetworkPrefix'), ".", FnFindInMap('EnvironmentType', 'ciinabox', 'StackOctet'), ".", ecs["SubnetOctet#{az}"], ".0/", FnFindInMap('EnvironmentType', 'ciinabox', 'SubnetMask')]))
      Property('AvailabilityZone', FnSelect(azId[az], FnGetAZs(Ref("AWS::Region"))))
    }
  end

  availability_zones.each do |az|
    Resource("SubnetRouteTableAssociationPrivate#{az}") {
      Type 'AWS::EC2::SubnetRouteTableAssociation'
      Property('SubnetId', Ref("SubnetPrivate#{az}"))
      Property('RouteTableId', Ref("RouteTablePrivate#{az}"))
    }
  end


  az_conditions
  az_count
  create_stack_log_group

  az_create_subnets(stacks['test']['subnet_allocation'], 'SubnetPrivate')
  subnets = az_conditional_resources('SubnetPrivate')



  Resource('PrivateNetworkAcl') do
    Type 'AWS::EC2::NetworkAcl'
    Property('VpcId', Ref('VPC'))
  end

  # Name: [RuleNumber, Protocol, RuleAction, Egress, CidrBlock, PortRange From, PortRange To]
  acls = {
    # Inbound rules
    InbloundNetworkAclEntry: ['100', '-1', 'allow', 'false', '0.0.0.0/0', '0', '65535'],
    # Outbound rules
    OutboundNetworkAclEntry: ['100', '-1', 'allow', 'true', '0.0.0.0/0', '0', '65535']
  }

  acls.each do |alcName, alcProperties|
    Resource(alcName) do
      Type 'AWS::EC2::NetworkAclEntry'
      Property('NetworkAclId', Ref('PrivateNetworkAcl'))
      Property('RuleNumber', alcProperties[0])
      Property('Protocol', alcProperties[1])
      Property('RuleAction', alcProperties[2])
      Property('Egress', alcProperties[3])
      Property('CidrBlock', alcProperties[4])
      Property('PortRange', From: alcProperties[5], To: alcProperties[6])
    end
  end

  maximum_availability_zones.times do |az|
    Resource("SubnetNetworkAclAssociationPrivate#{az}") do
      Condition "Az#{az}"
      Type 'AWS::EC2::SubnetNetworkAclAssociation'
      Property('SubnetId', Ref("SubnetPrivate#{az}"))
      Property('NetworkAclId', Ref('PrivateNetworkAcl'))
    end
  end

  rules = []
  rules << { IpProtocol: 'tcp', FromPort: '32768', ToPort: '65535', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType',Ref('EnvironmentType'),'NetworkPrefix'), ".", Ref('StackOctet'), ".0.0/16" ] )}
  rules << { IpProtocol: 'tcp', FromPort: '8089', ToPort: '8089', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType',Ref('EnvironmentType'),'NetworkPrefix'), ".", Ref('StackOctet'), ".0.0/16" ] )}
  rules << { IpProtocol: 'tcp', FromPort: '5557', ToPort: '5558', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType',Ref('EnvironmentType'),'NetworkPrefix'), ".", Ref('StackOctet'), ".0.0/16" ] )}

  Resource('SecurityGroupTest') do
    Type 'AWS::EC2::SecurityGroup'
    Property('VpcId', Ref('VPC'))
    Property('GroupDescription', 'External access to the ECS Test')
    Property('SecurityGroupIngress', rules)
  end

  policies = []
  policies << get_log_group_policy
  policies << {
    PolicyName: 'ecsServiceRole',
    PolicyDocument:
    {
      Statement:
      [
        {
          Effect: 'Allow',
          Action:
          [
            "ecs:CreateCluster",
            "ecs:DeregisterContainerInstance",
            "ecs:DiscoverPollEndpoint",
            "ecs:Poll",
            "ecs:RegisterContainerInstance",
            "ecs:StartTelemetrySession",
            "ecs:Submit*",
            "ec2:AuthorizeSecurityGroupIngress",
            "ec2:Describe*",
            "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
            "elasticloadbalancing:DeregisterTargets",
            "elasticloadbalancing:Describe*",
            "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
            "elasticloadbalancing:RegisterTargets"
          ],
          Resource: ['*']
        }
      ]
    }
  }

  policies << {
    PolicyName: 'describe-ec2-autoscaling',
    PolicyDocument:
    {
      Statement:
      [
        {
          Effect: 'Allow',
          Action:
          [
            'ec2:Describe*',
            'autoscaling:Describe*'
          ],
          Resource: ['*']
        }
      ]
    }
  }

  policies << {
    PolicyName: 'ecr-pull-images',
    PolicyDocument: {
      Statement: [
        {
          Effect: 'Allow',
          Action: [
            "ecr:BatchCheckLayerAvailability",
            "ecr:BatchGetImage",
            "ecr:Get*",
            "ecr:List*"
          ],
          Resource: ['*']
        }
      ]
    }
  }

  policies << {
    PolicyName: 's3-full-access',
    PolicyDocument: {
      Statement: [
        {
          Effect: 'Allow',
          Action: [
            "s3:*",
          ],
          Resource: ['*']
        }
      ]
    }
  }

  policies << {
    PolicyName: 'cloudwatch-logs',
    PolicyDocument: {
      Statement: [
        {
          Effect:'Allow',
          Action: [
            'logs:CreateLogGroup',
            'logs:CreateLogStream',
            'logs:PutLogEvents',
            'logs:DescribeLogStreams'
          ],
          Resource: [
            "arn:aws:logs:*:*:*"
          ]
        }
      ]
    }
  }

  policies << {
    PolicyName: 'attach-network-interfaces',
    PolicyDocument: {
      Statement: [
        {
          Effect:'Allow',
          Action: [
            'ec2:DescribeNetworkInterfaces',
            'ec2:AttachNetworkInterface',
            'ec2:DetachNetworkInterface',
            # 'ec2:CreateNetworkInterface',
            # 'ec2:DeleteNetworkInterface'
          ],
          Resource: [
            "*"
          ]
        }
      ]
    }
  }

  Resource('IamRole') do
    Type 'AWS::IAM::Role'
    Property(
      'AssumeRolePolicyDocument',
      Statement: [
        Effect: 'Allow',
        Principal: { Service: ['ec2.amazonaws.com'] },
        Action: ['sts:AssumeRole']
      ]
    )
    Property('Path', '/')
    Property('Policies', policies)
  end

  Resource('InstanceProfile') do
    Type 'AWS::IAM::InstanceProfile'
    Property('Path', '/')
    Property('Roles', [Ref('IamRole')])
  end

  Resource('TestECSCluster') do
    Type 'AWS::ECS::Cluster'
  end

  Resource("TestECSENI") {
    Type 'AWS::EC2::NetworkInterface'
    Property('SubnetId', Ref('SubnetPrivate0'))
    Property('GroupSet', [
      Ref('SecurityGroupTest'),
      Ref('SecurityGroupBackplane')
    ])
  }

  Resource('TestSlaveECSCluster') do
    Type 'AWS::ECS::Cluster'
  end

  LaunchConfiguration(:LaunchConfig) do
    ImageId FnFindInMap('TestAMI', Ref('AWS::Region'), 'ami')
    AssociatePublicIpAddress false
    IamInstanceProfile Ref('InstanceProfile')
    KeyName FnFindInMap('AccountId', Ref('AWS::AccountId'), 'KeyName')
    SecurityGroups [
      Ref('SecurityGroupTest'),
      Ref('SecurityGroupBackplane')
    ]
    InstanceType FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestInstanceType')
    BlockDeviceMappings [{DeviceName: '/dev/xvda',Ebs: { VolumeSize: 100, VolumeType: 'gp2'}}]
    UserData FnBase64(FnJoin('', [
      "#!/bin/bash\n",
      "INSTANCE_ID=$(echo `/opt/aws/bin/ec2-metadata -i | cut -f2 -d:`)\n",
      'echo ECS_CLUSTER=', Ref('TestECSCluster'), " >> /etc/ecs/ecs.config\n",
      "[ \"$(echo $(aws --region ", Ref('AWS::Region') , " ec2 describe-network-interfaces --filters --query 'NetworkInterfaces[?NetworkInterfaceId==`", Ref('TestECSENI'), "` && Status==`in-use`].Status'))\" == \"in-use\" ] || aws --region ", Ref('AWS::Region'), " ec2 attach-network-interface --network-interface-id ",  Ref('TestECSENI'), " --instance-id ${INSTANCE_ID} --device-index 1\n",
      "echo 'waiting for ECS ENI to attach' && sleep 20\n",
      "export NEW_HOSTNAME=", Ref('EnvironmentName') ,"-test-xx-`/opt/aws/bin/ec2-metadata --instance-id|/usr/bin/awk '{print $2}'`\n",
      "echo \"NEW_HOSTNAME=$NEW_HOSTNAME\" \n",
      "hostname $NEW_HOSTNAME\n",
      "sed -i -E \"s/^\(HOSTNAME=\).*/\\1$NEW_HOSTNAME/g\" /etc/sysconfig/network\n",
      "/opt/base2/bin/ec2-bootstrap ", Ref("AWS::Region"), " ", Ref('AWS::AccountId'), "\n",
      "service network restart\n",
      "stop ecs\n",
      "service docker stop\n",
      "service docker start\n",
      "start ecs\n",
      "echo 'done!!!!'\n"
    ]))
  end

  LaunchConfiguration(:LaunchConfigSlave) do
    ImageId FnFindInMap('TestAMI', Ref('AWS::Region'), 'ami')
    AssociatePublicIpAddress false
    IamInstanceProfile Ref('InstanceProfile')
    KeyName FnFindInMap('AccountId', Ref('AWS::AccountId'), 'KeyName')
    SecurityGroups [
      Ref('SecurityGroupTest'),
      Ref('SecurityGroupBackplane')
    ]
    InstanceType FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestInstanceType')
    BlockDeviceMappings [{DeviceName: '/dev/xvda',Ebs: { VolumeSize: 100, VolumeType: 'gp2'}}]
    UserData FnBase64(FnJoin('', [
      "#!/bin/bash\n",
      "INSTANCE_ID=$(echo `/opt/aws/bin/ec2-metadata -i | cut -f2 -d:`)\n",
      'echo ECS_CLUSTER=', Ref('TestSlaveECSCluster'), " >> /etc/ecs/ecs.config\n",
      "export NEW_HOSTNAME=", Ref('EnvironmentName') ,"-testslave-xx-`/opt/aws/bin/ec2-metadata --instance-id|/usr/bin/awk '{print $2}'`\n",
      "echo \"NEW_HOSTNAME=$NEW_HOSTNAME\" \n",
      "hostname $NEW_HOSTNAME\n",
      "sed -i -E \"s/^\(HOSTNAME=\).*/\\1$NEW_HOSTNAME/g\" /etc/sysconfig/network\n",
      "/opt/base2/bin/ec2-bootstrap ", Ref("AWS::Region"), " ", Ref('AWS::AccountId'), "\n",
      "service network restart\n",
      "stop ecs\n",
      "service docker stop\n",
      "service docker start\n",
      "start ecs\n",
      "echo 'done!!!!'\n"
    ]))
  end

  AutoScalingGroup('AutoScaleGroup') do
    UpdatePolicy("AutoScalingRollingUpdate", {
      "MinInstancesInService" => FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMinSize'),
      "MaxBatchSize"          => "1",
    })
    LaunchConfigurationName Ref('LaunchConfig')
    HealthCheckGracePeriod '500'
    MinSize FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMinSize')
    DesiredCapacity FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMinSize')
    MaxSize FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMaxSize')
    VPCZoneIdentifier [Ref('SubnetPrivate0')]
    TerminationPolicies ['NewestInstance']
    addTag('Name', FnJoin('', [Ref('EnvironmentName'), '-test-xx']), true)
    addTag('Environment', Ref('EnvironmentName'), true)
    addTag('EnvironmentType', Ref('EnvironmentType'), true)
    addTag('Role', 'everperform-runtime::ecs', true)
  end

  AutoScalingGroup('AutoScaleGroupSlave') do
    UpdatePolicy("AutoScalingRollingUpdate", {
      "MinInstancesInService" => FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMinSize'),
      "MaxBatchSize"          => "1",
    })
    LaunchConfigurationName Ref('LaunchConfigSlave')
    HealthCheckGracePeriod '500'
    MinSize FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMinSize')
    DesiredCapacity FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMinSize')
    MaxSize FnFindInMap('EnvironmentType', Ref('EnvironmentType'), 'TestECSMaxSize')
    VPCZoneIdentifier subnets
    TerminationPolicies ['NewestInstance']
    addTag('Name', FnJoin('', [Ref('EnvironmentName'), '-testslave-xx']), true)
    addTag('Environment', Ref('EnvironmentName'), true)
    addTag('EnvironmentType', Ref('EnvironmentType'), true)
    addTag('Role', 'everperform-runtime::ecs', true)
  end
  loadbalancers.each do |lb|
    Resource("#{lb["name"]}SecurityGroup") {
      Type "AWS::EC2::SecurityGroup"
      Property("VpcId", Ref("VPC"))
      Property("GroupDescription", "Access to #{lb["name"]} LoadBalancer")
      Property("SecurityGroupIngress", sg_create_rules(securityGroups["#{lb["name"]}LB"]))
      Property("Tags", [
        { Key: "Name", Value: FnJoin('-', [ Ref("EnvironmentName"), "#{lb["name"]}" ]) },
        { Key: "Environment", Value: Ref("EnvironmentName") },
        { Key: "EnvironmentType", Value: Ref("EnvironmentType") }
      ])
    }

    lb_atributes = []
    lb_atributes << { Key: "idle_timeout.timeout_seconds", Value: lb['idle_timeout'] } if lb.key?('idle_timeout')

    Resource("#{lb["name"]}LoadBalancer") {
      Type "AWS::ElasticLoadBalancingV2::LoadBalancer"
      Property("SecurityGroups", [ Ref("#{lb["name"]}SecurityGroup") ]) unless lb["type"] == 'network'
      if lb.key?('internal')
      Property("Subnets",az_conditional_resources("SubnetPrivate"))
      Property("Scheme", "internal")
      else
      Property("Subnets",az_conditional_resources("SubnetPublic"))
      end
      Property("Type", lb["type"]) if lb["type"] == 'network'
      Property("Tags",[
        { Key: "Name", Value: "#{lb["name"]}-LoadBalancer" },
        { Key: "Environment", Value: Ref("EnvironmentName") },
        { Key: "EnvironmentType", Value: Ref("EnvironmentType") }
      ])
      Property("LoadBalancerAttributes", lb_atributes) if lb_atributes.any?
    }

    defaults = {
      "healthcheck" => {
        "path" => "/",
        "port" => nil,
        "protocol" => 'HTTP',
        "interval" => 30,
        "timeout" => 10,
        "heathy_count" => 3,
        "unheathy_count" => 2,
        "code" => 200
      },
      "port" => 10,
      "protocol" => 'HTTP'
    }

    tg = lb.has_key?('default_targetgroup') ? defaults.deep_merge(lb['default_targetgroup']) : defaults

    Resource("#{lb["name"]}DefTargetGroup") {
      DependsOn("#{lb["name"]}LoadBalancer")
      Type "AWS::ElasticLoadBalancingV2::TargetGroup"
      if tg['healthcheck']['protocol'].downcase == 'tcp'
        Property("HealthCheckPort", tg['healthcheck']['port']) if !tg['healthcheck']['port'].nil?
        Property("HealthCheckProtocol", tg['healthcheck']['protocol'].upcase)
        Property("HealthCheckIntervalSeconds", tg['healthcheck']['interval'])
        Property("HealthCheckTimeoutSeconds", tg['healthcheck']['timeout'])
        Property("HealthyThresholdCount", tg['healthcheck']['threshold_count'])
        Property("UnhealthyThresholdCount", tg['healthcheck']['threshold_count'])
      else
        Property("HealthCheckPath", tg['healthcheck']['path'])
        Property("HealthCheckPort", tg['healthcheck']['port']) if !tg['healthcheck']['port'].nil?
        Property("HealthCheckProtocol", tg['healthcheck']['protocol'].upcase)
        Property("HealthCheckIntervalSeconds", tg['healthcheck']['interval'])
        Property("HealthCheckTimeoutSeconds", tg['healthcheck']['timeout'])
        Property("HealthyThresholdCount", tg['healthcheck']['heathy_count'])
        Property("UnhealthyThresholdCount", tg['healthcheck']['unheathy_count'])
        Property("Matcher", {
          HttpCode: tg['healthcheck']['code']
        })
      end
      Property("Port", tg['port'])
      Property("Protocol", tg['protocol'].upcase)
      Property("VpcId", Ref("VPC"))
      Property("Tags",[
        { Key: "Name", Value: "#{lb["name"]}-default-targetgroup" },
        { Key: "Environment", Value: Ref("EnvironmentName") },
        { Key: "EnvironmentType", Value: Ref("EnvironmentType") }
      ])
      Property("TargetGroupAttributes",[{ Key: "deregistration_delay.timeout_seconds", Value: "10"}])
    }

    Output("#{lb["name"]}DefTargetGroup") { Value(Ref("#{lb["name"]}DefTargetGroup")) }

    lb["listeners"].each do |listener|
      Resource("#{lb['name']}#{listener['name']}Listener") {
        DependsOn("#{lb["name"]}LoadBalancer")
        DependsOn("#{lb["name"]}DefTargetGroup")
        Type "AWS::ElasticLoadBalancingV2::Listener"
        if listener['protocol'] == 'http'
          Property("Protocol", "HTTP")
        elsif listener['protocol'] == 'tcp'
          Property("Protocol", "TCP")
        elsif listener['protocol'] == 'https'
          Property("Certificates", [{CertificateArn: FnFindInMap("AccountId", Ref("AWS::AccountId"),"SSLCertificateArn")}])
          Property("Protocol", "HTTPS")
        end
        Property("Port", listener['port'])
        Property("DefaultActions", [
          TargetGroupArn: Ref("#{lb["name"]}DefTargetGroup"),
          Type: "forward"
        ])
        Property("LoadBalancerArn", Ref("#{lb["name"]}LoadBalancer"))
      }

      Output("#{lb['name']}#{listener['name']}Listener") { Value(Ref("#{lb['name']}#{listener['name']}Listener")) }
    end

    lb['records'].each do |record|
      Resource("#{record.gsub('*','Wildcard')}LoadBalancerRecord") {
        Type "AWS::Route53::RecordSet"
        Property("HostedZoneName", FnJoin("", [ Ref("EnvironmentName"), ".", FnFindInMap("AccountId",Ref("AWS::AccountId"),"DnsDomain"), "." ]))
        if record == "apex"
          Property("Name", FnJoin("", [ Ref("EnvironmentName"), ".", FnFindInMap("AccountId",Ref("AWS::AccountId"),"DnsDomain"), "." ]))
        else
          Property("Name", FnJoin("", [ "#{record}.", Ref("EnvironmentName"), ".", FnFindInMap("AccountId",Ref("AWS::AccountId"),"DnsDomain"), "." ]))
        end
        Property("Type","A")
        Property("AliasTarget", {
          DNSName: FnGetAtt("#{lb["name"]}LoadBalancer","DNSName"),
          HostedZoneId: FnGetAtt("#{lb["name"]}LoadBalancer","CanonicalHostedZoneID")
        })
      }
    end
  end 
end
