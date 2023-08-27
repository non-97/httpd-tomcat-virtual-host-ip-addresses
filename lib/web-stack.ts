import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import { Vpc } from "./constructs/vpc";
import { WebEc2Instance } from "./constructs/web-ec2-instance";
import { ClientEc2Instance } from "./constructs/client-ec2-instance";

export class WebStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // VPC
    const vpc = new Vpc(this, "Vpc");

    // EC2 Instance
    const webEc2Instance = new WebEc2Instance(this, "WebEc2Instance", {
      vpc: vpc.vpc,
    });
    const clientEc2Instance = new ClientEc2Instance(this, "ClientEc2Instance", {
      vpc: vpc.vpc,
    });

    webEc2Instance.instance.connections.allowFrom(
      clientEc2Instance.instance,
      cdk.aws_ec2.Port.tcp(80)
    );
  }
}
