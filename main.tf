resource "aws_security_group" "bastion" {
  name        = var.name
  vpc_id      = var.vpc_id
  description = "Bastion security group (only SSH inbound access is allowed)"

  tags = {
    Name = var.name
  }
}

resource "aws_security_group_rule" "ssh_ingress" {
  type              = "ingress"
  from_port         = "22"
  to_port           = "22"
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr
  ipv6_cidr_blocks  = var.allowed_ipv6_cidr
  security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "ssh_sg_ingress" {
  count                    = length(var.allowed_security_groups)
  type                     = "ingress"
  from_port                = "22"
  to_port                  = "22"
  protocol                 = "tcp"
  source_security_group_id = element(var.allowed_security_groups, count.index)
  security_group_id        = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_all_egress" {
  type      = "egress"
  from_port = "0"
  to_port   = "65535"
  protocol  = "all"

  cidr_blocks = [
    "0.0.0.0/0",
  ]

  ipv6_cidr_blocks = [
    "::/0",
  ]

  security_group_id = aws_security_group.bastion.id
}

data "template_file" "user_data" {
  template = var.user_data_file != "" ? var.user_data_file : file("${path.module}/user_data.sh")

  vars = {
    s3_bucket_name              = var.s3_bucket_name
    s3_bucket_uri               = var.s3_bucket_uri
    ssh_user                    = var.ssh_user
    keys_update_frequency       = var.keys_update_frequency
    enable_hourly_cron_updates  = var.enable_hourly_cron_updates
    additional_user_data_script = var.additional_user_data_script
  }
}

//resource "aws_instance" "bastion" {
//  ami                    = "${var.ami}"
//  instance_type          = "${var.instance_type}"
//  iam_instance_profile   = "${var.iam_instance_profile}"
//  subnet_id              = "${var.subnet_id}"
//  vpc_security_group_ids = ["${aws_security_group.bastion.id}"]
//  user_data              = "${template_file.user_data.rendered}"
//
//  count                  = 1
//
//  tags {
//    Name = "${var.name}"
//  }
//}

resource "aws_launch_template" "bastion" {
  name_prefix   = "${var.name}-"
  image_id      = var.ami
  instance_type = var.instance_type

  user_data = base64encode(data.template_file.user_data.rendered)

  monitoring {
    enabled = var.enable_monitoring
  }

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip_address
    security_groups = compact(
      concat(
        [aws_security_group.bastion.id],
        split(",", var.security_group_ids),
      )
    )
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.instance_volume_size_gb
    }
  }

  iam_instance_profile {
    name = var.iam_instance_profile
  }

  key_name = var.key_name

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "bastion" {
  name = var.apply_changes_immediately ? "${var.name}-${aws_launch_template.bastion.latest_version}" : var.name

  vpc_zone_identifier = var.subnet_ids

  desired_capacity          = "1"
  min_size                  = "1"
  max_size                  = "1"
  health_check_grace_period = "60"
  health_check_type         = "EC2"
  force_delete              = false
  wait_for_capacity_timeout = 0

  launch_template {
    id      = aws_launch_template.bastion.id
    version = aws_launch_template.bastion.latest_version
  }

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  # Replace tags argument with tag blocks
  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }

  tag {
    key                 = "EIP"
    value               = var.eip
    propagate_at_launch = true
  }

  # Add extra tags from var.extra_tags
  dynamic "tag" {
    for_each = var.extra_tags
    content {
      key                 = tag.value.key
      value               = tag.value.value
      propagate_at_launch = tag.value.propagate_at_launch
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
