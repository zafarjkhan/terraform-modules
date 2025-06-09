
# ---------------------------------------------------------------------------------------------------------------------
# Launch Template for EC2 instances in the Auto Scaling Group
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_launch_template" "example" {
  name_prefix   = "terraform-"
  image_id      = "ami-053b0d53c279acc90" # Official Ubuntu 22.04 LTS AMI for us-east-1 as of June 2025
  instance_type = var.instance_type # Instance type for web servers

  # User data script to configure the instance on launch
  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.address
    db_port     = data.terraform_remote_state.db.outputs.port
  }))

  # Attach the security group for the instance
  vpc_security_group_ids = [aws_security_group.instance.id]
}

# ---------------------------------------------------------------------------------------------------------------------
# Auto Scaling Group for web servers
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_autoscaling_group" "example" {
  vpc_zone_identifier  = data.aws_subnets.default.ids # Subnets for the ASG

  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.asg.arn] # Attach to ALB target group
  health_check_type = "ELB"

  min_size = var.min_size # Minimum number of instances
  max_size = var.max_size # Maximum number of instances

  tag {
    # key                 = "Name"
    key                 = "${var.cluster_name}-Name"
    value               = "terraform-asg-example"
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Security group for EC2 instances
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_security_group" "instance" {
  name = var.instance_security_group_name

  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow inbound traffic on server port
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Application Load Balancer (ALB) and related resources
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_lb" "example" {
  # name               = var.alb_name
  name               = "${var.cluster_name}-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = local.http_port
  protocol          = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_target_group" "asg" {
  name     = var.alb_name
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Security group for the ALB
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port   = local.http_port
  to_port           = local.http_port
  protocol          = local.tcp_protocol
  cidr_blocks       = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port         = local.any_port
  to_port           = local.any_port
  protocol          = local.any_port
  cidr_blocks       = local.all_ips
}

resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"
  # name = var.alb_security_group_name

  # # Allow inbound HTTP requests
  # ingress {
  #   from_port   = local.http_port
  #   to_port     = local.http_port
  #   protocol    = local.tcp_protocol
  #   cidr_blocks = local.all_ips
  # }

  # # Allow all outbound requests
  # egress {
  #   from_port   = local.any_port
  #   to_port     = local.any_port
  #   protocol    = local.any_protocol
  #   cidr_blocks = local.all_ips
  # }
}

# ---------------------------------------------------------------------------------------------------------------------
# Data sources for remote state and networking
# ---------------------------------------------------------------------------------------------------------------------
data "terraform_remote_state" "db" {
  backend = "s3"
  config = {
    bucket = var.db_remote_state_bucket
    key    = var.db_remote_state_key
    region = "us-east-1"
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}


# ---------------------------------------------------------------------------------------------------------------------
# End of configuration
# ---------------------------------------------------------------------------------------------------------------------