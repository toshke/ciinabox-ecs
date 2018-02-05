require_relative './utils'

def listener_parameters(loadbalancers)
  loadbalancers.each do |lb|
    Parameter("#{lb["name"]}LoadBalancer") { Type "String" }
    lb['targetgroups'].each do |target|
      Parameter("#{lb['name']}#{target['name']}TargetGroup") { Type "String" }
    end if lb.key? ('targetgroups')
    lb['listeners'].each do |listener|
      Parameter("#{lb['name']}#{listener['name']}Listener") { Type "String" }
    end if lb.key? ('listeners')
  end
end

def master_listener_params(stack,params,loadbalancers)
  loadbalancers.each do |lb|
    params.merge!("#{lb["name"]}LoadBalancer" => FnGetAtt(stack, "Outputs.#{lb['name']}LoadBalancer"))
    lb['targetgroups'].each do |target|
      params.merge!("#{lb['name']}#{target['name']}TargetGroup" => FnGetAtt(stack, "Outputs.#{lb['name']}#{target['name']}TargetGroup"))
    end if lb.key? ('targetgroups')
    lb['listeners'].each do |listener|
      params.merge!("#{lb['name']}#{listener['name']}Listener" => FnGetAtt(stack, "Outputs.#{lb['name']}#{listener['name']}Listener"))
    end if lb.key? ('listeners')
  end
end

def create_target_group(name,tg={},network=nil)
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
  if tg.key?('type')
    if tg['type'] == 'network'
      defaults = {
          "healthcheck" => {
              "port" => nil,
              "protocol" => 'TCP',
              "interval" => 30,
              "timeout" => 10,
              "heathy_count" => 3,
              "unheathy_count" => 3
          },
          "port" => 10,
          "protocol" => 'TCP'
      }
    end
  end

  tg = defaults.deep_merge(tg)

  Resource("#{name.capitalize}TargetGroup") {
    Type "AWS::ElasticLoadBalancingV2::TargetGroup"
    Property("HealthCheckPort", tg['healthcheck']['port']) if !tg['healthcheck']['port'].nil?
    Property("HealthCheckProtocol", tg['healthcheck']['protocol'])
    Property("HealthCheckIntervalSeconds", tg['healthcheck']['interval'])
    Property("HealthCheckTimeoutSeconds", tg['healthcheck']['timeout'])
    Property("HealthyThresholdCount", tg['healthcheck']['heathy_count'])
    Property("UnhealthyThresholdCount", tg['healthcheck']['unheathy_count'])
    if !tg.key?('type')
      Property("HealthCheckPath", tg['healthcheck']['path'])
      Property("Matcher", {
          HttpCode: tg['healthcheck']['code']
      })
    end
    if tg.has_key?('sticky')
      Property('TargetGroupAttributes', [
          { Key: 'stickiness.enabled', Value: true },
          { Key: 'stickiness.type', Value: 'lb_cookie' },
          { Key: 'stickiness.lb_cookie.duration_seconds', Value: tg['sticky'].to_s } # = 1 day NOTE: Max is 7 days 604800 seconds
      ])
    end
    if network == 'awsvpc'
      Property('TargetType','ip')
    end
    Property("Port", tg['port'])
    Property("Protocol", tg['protocol'])
    Property("VpcId", Ref("VPC"))
    Property("Tags",[
        { Key: "Name", Value: "#{name}-targetgroup" },
        { Key: "Environment", Value: Ref("EnvironmentName") }
    ])
  }
end

def ref_target_group(name)
  Ref("#{name.capitalize}TargetGroup")
end

def ref_default_target_group(loadbalancer,targetgroup)
  Ref("#{loadbalancer}#{targetgroup}TargetGroup")
end

def create_listener_rule(name,params)
  params['listeners'].each_with_index do |listener,index|
    params['conditions'].each_with_index do |condition,offset|
      rule_name = "#{name.capitalize}#{listener.upcase}#{offset if offset > 0}ListenerRule"
      Resource(rule_name) {
        Type "AWS::ElasticLoadBalancingV2::ListenerRule"
        Property("Actions",[
            { Type: "forward", TargetGroupArn: ref_target_group(name) }
        ])
        Property("Conditions", listener_conditions(condition))
        Property("ListenerArn", Ref("#{params['loadbalancer']}#{listener}Listener"))
        Property("Priority", (params['priority'].to_i + index + offset))
      }
    end
  end
end

def listener_conditions(condition)
  listener_conditions = []
  if condition.key?("path")
    listener_conditions << { Field: "path-pattern", Values: [ condition["path"] ] }
  end
  if condition.key?("host")
    hosts = []
    if condition["host"].include?('.')
      hosts << condition["host"]
    else
      hosts << FnJoin("", [ condition["host"], ".", Ref("EnvironmentName"), ".", FnFindInMap("AccountId",Ref("AWS::AccountId"),"DnsDomain") ])
    end
    listener_conditions << { Field: "host-header", Values: hosts }
  end
  listener_conditions
end


def create_network_listener(name,params)
  Resource("#{name}Listener") {
    Type "AWS::ElasticLoadBalancingV2::Listener"
    Property("Protocol", "TCP")
    Property("Port", params['port'])
    Property("DefaultActions", [
        TargetGroupArn: ref_target_group(name),
        Type: "forward"
    ])
    Property("LoadBalancerArn", Ref("#{params["loadbalancer"]}LoadBalancer"))
  }
end