$default_retention_in_days = 14

def create_stack_log_group(retention_in_days=$default_retention_in_days)
  Resource('LogGroup') {
    Type 'AWS::Logs::LogGroup'
    Property('LogGroupName', Ref('AWS::StackName'))
    Property('RetentionInDays', "#{retention_in_days}")
  }
  Output('LogGroup') { Value(ref_log_group) }
end

def ref_log_group
  return Ref('LogGroup')
end

def get_log_group_arn
  return FnGetAtt('LogGroup', 'Arn')
end

def get_log_group_policy()
  return {
    PolicyName: 'cloudwatch',
    PolicyDocument: {
      Statement: [
        {
          Effect: 'Allow',
          Action: [
            'logs:CreateLogStream',
            'logs:PutLogEvents',
            'logs:DescribeLogStreams'
          ],
          Resource: ['*']
        }
      ]
    }
  }
end

def create_log_group_filter(metric_configs, log_group)
  metric_configs.each do |metric_config|
    Resource("#{metric_config['name']}MetricFilter") {
      Type 'AWS::Logs::MetricFilter'
      Property('LogGroupName', log_group)
      Property('FilterPattern', metric_config['filter_pattern'])
      Property('MetricTransformations',[{
          MetricNamespace: build_namespace(metric_config['metric']['namespace']),
          MetricName: metric_config['metric']['name'],
          MetricValue: metric_config['metric']['value']
      }])
    }
  end
end

def build_namespace(metric_namespace)
  if metric_namespace.include? '!EnvironmentName'
    namespace = []
    ns = metric_namespace.split('-')
    ns.each do |s|
      if s.include? '!'
        namespace << "Ref(\"#{s.gsub(/\!/, '')}\")"
      else
        namespace << "\"#{s}\""
      end
    end
    return eval("FnJoin(\"-\", [#{namespace.join(',')}])")
  end
  metric_namespace
end
