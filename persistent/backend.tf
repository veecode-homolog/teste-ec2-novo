terraform {
  backend "s3" {
    bucket = "veecode-homolog-terraform-state"
    key    = "teste-ec2-novo/persistent.tfstate"
    region = "us-east-1"
  }
}