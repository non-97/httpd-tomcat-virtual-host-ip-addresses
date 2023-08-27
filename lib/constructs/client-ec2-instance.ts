import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";

export interface ClientEc2InstanceProps {
  vpc: cdk.aws_ec2.IVpc;
}

export class ClientEc2Instance extends Construct {
  readonly instance: cdk.aws_ec2.Instance;

  constructor(scope: Construct, id: string, props: ClientEc2InstanceProps) {
    super(scope, id);

    // EC2 Instance
    this.instance = new cdk.aws_ec2.Instance(this, "Default", {
      machineImage: cdk.aws_ec2.MachineImage.latestAmazonLinux2023({
        cachedInContext: true,
      }),
      instanceType: new cdk.aws_ec2.InstanceType("t3.micro"),
      vpc: props.vpc,
      vpcSubnets: props.vpc.selectSubnets({
        subnetGroupName: "Public",
      }),
      propagateTagsToVolumeOnCreation: true,
      ssmSessionPermissions: true,
      requireImdsv2: true,
    });
  }
}
