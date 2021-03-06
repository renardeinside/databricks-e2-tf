## Example Terraform code for deploying a Databricks E2 workspace

Please remember, these configurations are needed for **workspace creation**. 

## How-to

- Install [terraform](https://www.terraform.io/) on your local machine (or inside your CI pipeline)
- Authorize to AWS CLI
- Create a new local file with terraform variables, called `.tfvars` in the same folder with `main.tf`
- Provide the variables in the file as described in `.tfvars.example`
- Install plugins:
```
terraform init
```
- Plan the deployment:
```
terraform plan -var-file=.tfvars
```
- Deploy components:
```
terraform apply -var-file=.tfvars
```

After the deployment, you'll see the databricks host in the output. 
For the first log in as administrator, please use the same email and password as for https://accounts.cloud.databricks.com/. 

Please note the following:
- VPC permissions might be too extensive depending on your environment. You can add more limitations to the existing configuration.
- You might require specific permissions on AWS level. To verify the permission boundary, please check Databricks documentation.
