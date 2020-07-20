provider "aws" {
  region     = "ap-south-1"
  profile    = "ver2"
}


provider "kubernetes" {
  //By Default works on Current Context
}



variable "key" {
	default = "webkey"
}


//CREATING KEY
resource "tls_private_key" "webtls" {
  algorithm   = "RSA"
  rsa_bits    = "4096"
}


//KEY IMPORTING
resource "aws_key_pair" "webkey" {
  depends_on=[tls_private_key.webtls]
  key_name   = var.key
  public_key = tls_private_key.webtls.public_key_openssh
}


//SAVING PRIVATE
resource "local_file" "webfile" {
  depends_on = [tls_private_key.webtls]

  content  = tls_private_key.webtls.private_key_pem
  filename = "$(var.key).pem"
  file_permission= 0400
}



//CREATING VPC
resource "aws_vpc" "webvpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_hostnames = true
  enable_dns_support = true
  assign_generated_ipv6_cidr_block = true
  tags = {
    Name = "webvpc"
  }
}


//INTERNET GATEWAY
resource "aws_internet_gateway" "webgw" {
depends_on = [ aws_vpc.webvpc  ]
  vpc_id = aws_vpc.webvpc.id

  tags = {
    Name = "webgw"
  }
}

//ROUTE RULE
resource "aws_route" "webr" {
depends_on = [ aws_vpc.webvpc ,  aws_internet_gateway.webgw ]

  route_table_id            = aws_vpc.webvpc.default_route_table_id
  destination_cidr_block    = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.webgw.id
  }


// ADDING RULE TO SECURITY
resource "aws_default_security_group" "websg1" {
depends_on = [
    aws_vpc.webvpc
  ]
  vpc_id = aws_vpc.webvpc.id

  ingress {
    description = "ssh"
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "http"
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "https"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "WebSG"
  }
}


//CREATING SUBNET
resource "aws_subnet" "websub" {

depends_on = [
    aws_vpc.webvpc
  ]

  availability_zone= "ap-south-1b"
  vpc_id     = aws_vpc.webvpc.id
  cidr_block = "10.0.0.0/16"
  map_public_ip_on_launch = true

  tags = {
    Name = "websub"
  }
}

//CREATING SUBNET 2
resource "aws_subnet" "websub2" {

depends_on = [
    aws_vpc.webvpc
  ]

  availability_zone= "ap-south-1c"
  vpc_id     = aws_vpc.webvpc.id
  cidr_block = "10.0.0.0/16"
  map_public_ip_on_launch = true

  tags = {
    Name = "websub2"
  }
}


//CREATING ROLE FOR EKS CLUSTER
resource "aws_iam_role" "wprole" {
  name = "eks-cluster-role"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

//CREATING IAM ROLE FOR NG
resource "aws_iam_role" "ng-role" {
  name = "eks-ng-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}


//ATTACHING POLICIES TO ROLE 
resource "aws_iam_role_policy_attachment" "EKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = "${aws_iam_role.wprole.name}"
}

resource "aws_iam_role_policy_attachment" "EKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = "${aws_iam_role.wprole.name}"
}
//ATTACHING POLICIES TO NODE GROUPS
resource "aws_iam_role_policy_attachment" "EKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.ng-role.name
}

resource "aws_iam_role_policy_attachment" "EKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.ng-role.name
}

resource "aws_iam_role_policy_attachment" "EC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.ng-role.name
}


//CREATING EKS CLUSTER
resource "aws_eks_cluster" "wpcluster" {
  name     = "my-eks-cluster"
  role_arn = "${aws_iam_role.wprole.arn}"

  vpc_config {
    subnet_ids = ["${aws_subnet.websub.id}","${aws_subnet.websub2.id}" ]
  }

  depends_on = [
    aws_subnet.websub,
    aws_subnet.websub2,
    aws_iam_role_policy_attachment.EKSClusterPolicy,
    aws_iam_role_policy_attachment.EKSServicePolicy,
  ]
}





//CREATING NODE GROUP 1
resource "aws_eks_node_group" "ng1" {
  cluster_name    = aws_eks_cluster.wpcluster.name
  node_group_name = "node-group-1"
  node_role_arn   = aws_iam_role.ng-role.arn
  subnet_ids = ["${aws_subnet.websub.id}","${aws_subnet.websub2.id}" ]
  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  instance_types = ["t2.micro"]

  remote_access {
    ec2_ssh_key               = var.key
    source_security_group_ids = [aws_vpc.webvpc.default_security_group_id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.EKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.EKS_CNI_Policy,
    aws_iam_role_policy_attachment.EC2ContainerRegistryReadOnly,
    aws_eks_cluster.wpcluster
  ]
}


//CREATING NODE GROUP 2
resource "aws_eks_node_group" "ng2" {
  cluster_name    = aws_eks_cluster.wpcluster.name
  node_group_name = "node-group-2"
  node_role_arn   = aws_iam_role.ng-role.arn
  subnet_ids = ["${aws_subnet.websub.id}","${aws_subnet.websub2.id}" ]
  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  instance_types = ["t2.micro"]

  remote_access {
    ec2_ssh_key               = var.key
    source_security_group_ids = [aws_vpc.webvpc.default_security_group_id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.EKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.EKS_CNI_Policy,
    aws_iam_role_policy_attachment.EC2ContainerRegistryReadOnly,
    aws_eks_cluster.wpcluster
  ]
}



//UPDATING KUBECTL CONFIG FILE
resource "null_resource" "update-kube-config" {
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name my-eks-cluster"
  }
  depends_on = [
    aws_eks_node_group.ng1,
    aws_eks_node_group.ng2
  ]
}


//CREATING PVC FOR WORDPRESS POD
resource "kubernetes_persistent_volume_claim" "wp-pvc" {
  metadata {
    name   = "wp-pvc"
    labels = {
      env     = "Testing"
      Country = "India" 
    }
  }

  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}



//CREATING PVC FOR MYSQL POD
resource "kubernetes_persistent_volume_claim" "MySqlPVC" {
  metadata {
    name   = "mysql-pvc"
    labels = {
      env     = "Testing"
      Country = "India" 
    }
  }

  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}
//CREATING DEPLOYMENT FOR MYSQL POD
resource "kubernetes_deployment" "MySql-dep" {
  metadata {
    name   = "mysql-dep"
    labels = {
      env     = "Testing"
      Country = "India" 
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        pod     = "mysql"
        env     = "Testing"
        Country = "India" 
      }
    }

    template {
      metadata {
        labels = {
          pod     = "mysql"
          env     = "Testing"
          Country = "India" 
        }
      }

      spec {
        volume {
          name = "mysql-vol"
          persistent_volume_claim { 
            claim_name = "${kubernetes_persistent_volume_claim.MySqlPVC.metadata.0.name}"
          }
        }

        container {
          image = "mysql:5.6"
          name  = "mysql-container"

          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = "root@123"
          }
          env {
            name  = "MYSQL_DATABASE"
            value = "wpdb"
          }
          env {
            name  = "MYSQL_USER"
            value = "user"
          }
          env{
            name  = "MYSQL_PASSWORD"
            value = "passwd"
          }

          volume_mount {
              name       = "mysql-vol"
              mount_path = "/var/lib/mysql"
          }

          port {
            container_port = 80
          }
        }
      }
    }
  }
}



//CRAETING DEPLOYMENT FOR WORDPRESS
resource "kubernetes_deployment" "wp-dep" {
  metadata {
    name   = "wp-dep"
    labels = {
      env     = "Testing"
      Country = "India" 
    }
  }
  depends_on = [
    kubernetes_deployment.MySql-dep, 
    kubernetes_service.MySqlService
  ]

  spec {
    replicas = 2
    selector {
      match_labels = {
        pod     = "wp"
        env     = "Testing"
        Country = "India" 
        
      }
    }

    template {
      metadata {
        labels = {
          pod     = "wp"
          env     = "Testing"
          Country = "India"  
        }
      }

      spec {
        volume {
          name = "wp-vol"
          persistent_volume_claim { 
            claim_name = "${kubernetes_persistent_volume_claim.wp-pvc.metadata.0.name}"
          }
        }

        container {
          image = "wordpress:4.8-apache"
          name  = "wp-container"

          env {
            name  = "WORDPRESS_DB_HOST"
            value = "${kubernetes_service.MySqlService.metadata.0.name}"
          }
          env {
            name  = "WORDPRESS_DB_USER"
            value = "user"
          }
          env {
            name  = "WORDPRESS_DB_PASSWORD"
            value = "passwd"
          }
          env{
            name  = "WORDPRESS_DB_NAME"
            value = "wpdb"
          }
          env{
            name  = "WORDPRESS_TABLE_PREFIX"
            value = "wp_"
          }

          volume_mount {
              name       = "wp-vol"
              mount_path = "/var/www/html/"
          }

          port {
            container_port = 80
          }
        }
      }
    }
  }
}


//SETTING LOAD BALANCER
resource "kubernetes_service" "wpService" {
  metadata {
    name   = "wp-svc"
    labels = {
      env     = "Testing"
      Country = "India" 
    }
  }  

  depends_on = [
    kubernetes_deployment.wp-dep
  ]

  spec {
    type     = "LoadBalancer"
    selector = {
      pod = "wp"
    }

    port {
      name = "wp-port"
      port = 80
    }
  }
}

//SETTING CLUSTER IP FOR MYSQL
resource "kubernetes_service" "MySqlService" {
  metadata {
    name   = "mysql-svc"
    labels = {
      env     = "Testing"
      Country = "India" 
    }
  }  
  depends_on = [
    kubernetes_deployment.MySql-dep
  ]

  spec {
    selector = {
      pod = "mysql"
    }
  
    cluster_ip = "None"
    port {
      name = "mysql-port"
      port = 3306
    }
  }
}

//HALT FOR EVERYTHING SETUP
resource "time_sleep" "wait_60_seconds" {
  create_duration = "60s"
  depends_on = [kubernetes_service.wpService]  
}

//OPEN BROWSER
resource "null_resource" "open_wp" {
  provisioner "local-exec" {
    command = "start chrome ${kubernetes_service.wpService.load_balancer_ingress.0.hostname}"
  }

  depends_on = [
    time_sleep.wait_60_seconds
  ]
}
