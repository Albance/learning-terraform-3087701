######################################
# DATA SOURCE: Get latest Bitnami AMI
######################################
data "aws_ami" "app_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["bitnami-tomcat-*-x86_64-hvm-ebs-nami"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["979382823631"] # Bitnami official account
}

#############################
# VPC with 3 public subnets
#############################
module "blog_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "dev"
  cidr = "10.0.0.0/16"

  # 3 Availability Zones (multi-AZ setup)
  azs            = ["us-west-2a", "us-west-2b", "us-west-2c"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

#####################################################
# Security Group allowing inbound HTTP/HTTPS access
#####################################################
module "blog_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.13.0"

  name   = "blog"
  vpc_id = module.blog_vpc.vpc_id

  ingress_rules       = ["https-443-tcp", "http-80-tcp"] # Allow HTTP and HTTPS
  ingress_cidr_blocks = ["0.0.0.0/0"]                    # Open to the world
  egress_rules        = ["all-all"]                      # Allow all outbound
  egress_cidr_blocks  = ["0.0.0.0/0"]
}

######################################
# Application Load Balancer (ALB)
######################################
module "blog_alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name               = "blog-alb"
  load_balancer_type = "application"

  vpc_id          = module.blog_vpc.vpc_id
  subnets         = module.blog_vpc.public_subnets
  security_groups = [module.blog_sg.security_group_id]

  # ✅ Ensure deletion protection is disabled
  load_balancer_attributes = [
    {
      key   = "deletion_protection.enabled"
      value = "false"
    }
  ]

  # Register EC2 instances to this target group
  target_groups = [
    {
      name_prefix      = "blog-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]

  # Listener for HTTP traffic on port 80
  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = {
    Environment = "dev"
  }
}

#########################################
# Auto Scaling Group (ASG) for EC2 fleet
#########################################
module "blog_autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "6.5.2"

  name = "blog"

  min_size            = 1   # Minimum number of instances
  max_size            = 2   # Maximum number of instances
  instance_type       = var.instance_type  # e.g. t3.micro
  image_id            = data.aws_ami.app_ami.id

  vpc_zone_identifier = module.blog_vpc.public_subnets         # ASG instances in public subnets
  target_group_arns   = module.blog_alb.target_group_arns      # Attach to ALB
  security_groups     = [module.blog_sg.security_group_id]     # Use same SG as ALB
}
