# Instructions: Place your core Terraform Module configuration below

module "module-aws-tf-cicd" {
  source = "../modules/module-aws-tf-cicd"

  # GitHub 연동 설정
  github_connection_name = "github-terraform-cicd"
  github_repository      = "sangbeome/workshop-terraform-cicd-and-testing-on-aws"
  github_branch          = "main"

  # CodeBuild Projects
  codebuild_projects = {
    tf_test : {
      name               = "TerraformTest-github"
      description        = "Terraform Test for GitHub source"
      path_to_build_spec = "./buildspec/tf-test-buildspec.yml"
    },
    tf_apply : {
      name               = "TerraformApply-github"
      description        = "Terraform Apply for GitHub source"
      path_to_build_spec = "./buildspec/tf-apply-buildspec.yml"
    }
  }

  # GitHub 소스를 사용하는 CodePipeline
  codepipeline_pipelines = {
    github_pipeline : {
      name          = "terraform-cicd-github"
      source_type   = "GitHub"
      github_repo   = "sangbeome/workshop-terraform-cicd-and-testing-on-aws"
      github_branch = "main"

      tags = {
        "Description" = "Pipeline connected to GitHub"
        "Source"      = "GitHub"
      }

      stages = [
        {
          name = "Source"
          action = [
            {
              name     = "Source"
              category = "Source"
              owner    = "AWS"
              provider = "CodeStarSourceConnection"
              version  = "1"
              configuration = {
                ConnectionArn    = module.module-aws-tf-cicd.github_connection_arn
                FullRepositoryId = "sangbeome/workshop-terraform-cicd-and-testing-on-aws"
                BranchName       = "main"
              }
              input_artifacts  = []
              output_artifacts = ["source_output"]
              run_order        = 1
            },
          ]
        },
        {
          name = "Test"
          action = [
            {
              name     = "TerraformTest"
              category = "Build"
              owner    = "AWS"
              provider = "CodeBuild"
              version  = "1"
              configuration = {
                ProjectName = "TerraformTest-github"
              }
              input_artifacts  = ["source_output"]
              output_artifacts = ["test_output"]
              run_order        = 2
            },
          ]
        },
        {
          name = "Apply"
          action = [
            {
              name     = "TerraformApply"
              category = "Build"
              owner    = "AWS"
              provider = "CodeBuild"
              version  = "1"
              configuration = {
                ProjectName = "TerraformApply-github"
              }
              input_artifacts  = ["source_output"]
              output_artifacts = ["apply_output"]
              run_order        = 3
            },
          ]
        },
      ]
    }
  }
}

output "github_connection_arn" {
  description = "GitHub CodeStar Connection ARN - AWS 콘솔에서 연결 승인 필요"
  value       = module.module-aws-tf-cicd.github_connection_arn
}

output "github_connection_status" {
  description = "GitHub 연결 상태 (PENDING이면 AWS 콘솔에서 승인 필요)"
  value       = module.module-aws-tf-cicd.github_connection_status
}
