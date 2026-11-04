# Private ECR repositories for the platform's own images (cop/ecommerce-api,
# cop/incident-api). Tags are immutable: a deploy names an exact image.

variable "names" {
  type = set(string)
}

# Images kept per repository; older ones expire.
variable "keep_images" {
  type    = number
  default = 10
}

# true deletes the repository even if it still holds images.
variable "force_delete" {
  type    = bool
  default = false
}

resource "aws_ecr_repository" "this" {
  for_each             = var.names
  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Untagged images (failed or replaced pushes)"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the newest ${var.keep_images} images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.keep_images }
        action       = { type = "expire" }
      },
    ]
  })
}

output "arns" {
  value = [for r in aws_ecr_repository.this : r.arn]
}

output "urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
