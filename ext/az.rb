$maximum_availability_zones = 5
$subnet_multiplier = 8

def az_conditions(x = $maximum_availability_zones)
  x.times do |az|
    Condition("Az#{az}", FnNot([FnEquals(FnFindInMap(Ref('AWS::AccountId'), Ref('AWS::Region'), az), false)]))
  end
end

def az_count(x = $maximum_availability_zones)
  x.times do |i|
    tf = []
    (i + 1).times do |y|
      tf << { 'Condition' => "Az#{y}" }
    end
    (x - (i + 1)).times do |z|
      tf << FnNot(['Condition' => "Az#{i + z + 1}"])
    end
    Condition("#{i + 1}Az", FnAnd(tf))
  end
end

def az_conditional_resources(resource_name, x = $maximum_availability_zones)
  if x.to_i > 0
    resources = []
    x.times do |y|
      resources << Ref("#{resource_name}#{y}")
    end
    if_statement = FnIf("#{x}Az", resources, az_conditional_resources(resource_name, x - 1))
    if_statement
  else
    Ref("#{resource_name}#{x}")
  end
end

def az_conditional_resources_names(resource_name, x = $maximum_availability_zones)
  if x.to_i > 0
    resources = []
    x.times do |y|
      resources << "#{resource_name}#{y}"
    end
    if_statement = FnIf("#{x}Az", resources, az_conditional_resources_names(resource_name, x - 1))
    if_statement
  else
    "#{resource_name}#{x}"
  end
end

def az_conditional_resources_array(resource_name, x = $maximum_availability_zones)
  if x.to_i > 0
    if_statement = FnIf("#{x}Az", resource_name[x - 1], az_conditional_resources_array(resource_name, x - 1))
    if_statement
  else
    resource_name[0]
  end
end

def az_create_subnets(subnet_allocation, subnet_name, vpc = 'VPC', x = $maximum_availability_zones, subnet_multiplier = $subnet_multiplier)
  subnets = []
  x.times do |az|
    Resource("#{subnet_name}#{az}") do
      Condition "Az#{az}"
      Type 'AWS::EC2::Subnet'
      Property('VpcId', Ref(vpc.to_s))
      Property('CidrBlock', FnJoin('', ['10.', Ref('StackOctet'), ".#{subnet_allocation * subnet_multiplier + az}.0/24"]))
      Property('AvailabilityZone', FnFindInMap(Ref('AWS::AccountId'), Ref('AWS::Region'), az))
      Property('Tags', [{ Key: 'Name', Value: "#{subnet_name}#{az}" }])
    end
    subnets << "#{subnet_name}#{az}"
  end
  subnets
end

def az_create_private_route_associations(subnet_name, x = $maximum_availability_zones)
  x.times do |az|
    Resource("RouteTableAssociation#{subnet_name}#{az}") do
      Condition "Az#{az}"
      Type 'AWS::EC2::SubnetRouteTableAssociation'
      Property('SubnetId', Ref("#{subnet_name}#{az}"))
      Property('RouteTableId', Ref("RouteTablePrivate#{az}"))
    end
  end
end
