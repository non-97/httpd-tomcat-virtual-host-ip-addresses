import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as fs from "fs";
import * as path from "path";

export interface WebEc2InstanceProps {
  vpc: cdk.aws_ec2.IVpc;
}

export class WebEc2Instance extends Construct {
  readonly instance: cdk.aws_ec2.Instance;

  constructor(scope: Construct, id: string, props: WebEc2InstanceProps) {
    super(scope, id);

    // Key pair
    const keyName = "test-key-pair";
    const keyPair = new cdk.aws_ec2.CfnKeyPair(this, "KeyPair", {
      keyName,
    });
    keyPair.applyRemovalPolicy(cdk.RemovalPolicy.DESTROY);

    // User data
    const userDataScript = fs.readFileSync(
      path.join(__dirname, "../ec2/user-data.sh"),
      "utf8"
    );
    const userData = cdk.aws_ec2.UserData.forLinux({
      shebang: "#!/bin/bash",
    });
    userData.addCommands(userDataScript);

    // Instance
    this.instance = new cdk.aws_ec2.Instance(this, "Default", {
      machineImage: cdk.aws_ec2.MachineImage.lookup({
        name: "RHEL-9.2.0_HVM-20230726-x86_64-61-Hourly2-GP2",
        owners: ["309956199498"],
      }),
      instanceType: new cdk.aws_ec2.InstanceType("t3.micro"),
      blockDevices: [
        {
          deviceName: "/dev/sda1",
          volume: cdk.aws_ec2.BlockDeviceVolume.ebs(10, {
            volumeType: cdk.aws_ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
          }),
        },
      ],
      vpc: props.vpc,
      vpcSubnets: props.vpc.selectSubnets({
        subnetGroupName: "Public",
      }),
      keyName,
      ssmSessionPermissions: true,
      userData,
      requireImdsv2: false,
    });

    // ENI
    const cfnInstance = this.instance.node
      .defaultChild as cdk.aws_ec2.CfnInstance;
    cfnInstance.networkInterfaces = [
      {
        deviceIndex: "0",
        subnetId: props.vpc.selectSubnets({
          subnetGroupName: "Public",
          onePerAz: true,
        }).subnetIds[0],
        secondaryPrivateIpAddressCount: 1,
        groupSet: [this.instance.connections.securityGroups[0].securityGroupId],
      },
    ];
    cfnInstance.addPropertyDeletionOverride("SecurityGroupIds");
    cfnInstance.addPropertyDeletionOverride("SubnetId");

    // Output
    // Key pair
    new cdk.CfnOutput(this, "GetSecretKeyCommand", {
      value: `aws ssm get-parameter --name /ec2/keypair/${keyPair.getAtt(
        "KeyPairId"
      )} --region ${
        cdk.Stack.of(this).region
      } --with-decryption --query Parameter.Value --output text > ./key-pair/${keyName}.pem`,
    });
  }
}
