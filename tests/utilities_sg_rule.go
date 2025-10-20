package test

import (
	"fmt"
	"testing"
	"time"
	"strings"
    "github.com/aws/aws-sdk-go/aws"
    "github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/cloudwatchlogs"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

func getLogStreamEvents(logGroup, logStream string) (string, error) {
    sess := session.Must(session.NewSession())
    svc := cloudwatchlogs.New(sess)

    input := &cloudwatchlogs.GetLogEventsInput{
        LogGroupName:  &logGroup,
        LogStreamName: &logStream,
        Limit:         aws.Int64(100),
    }

    result, err := svc.GetLogEvents(input)
    if err != nil {
        return "", err
    }

    var messages string
    for _, event := range result.Events {
        messages += *event.Message + "\n"
    }
    fmt.Sprintf("DEBUG>%s", messages)
    return messages, nil
}

func testSGRule(t *testing.T, variant string) {
	t.Parallel()

	terraformDir := fmt.Sprintf("../examples/%s", variant)

	terraformOptions := &terraform.Options{
		TerraformDir: terraformDir,
		LockTimeout:  "5m",
		Upgrade:      true,
	}

	defer terraform.Destroy(t, terraformOptions)

	terraform.InitAndApply(t, terraformOptions)

    if variant == "basic-ec2" {
        log_group := terraform.Output(t, terraformOptions, "log_group")
        log_stream := terraform.Output(t, terraformOptions, "log_stream")
        found := false
        for i := 0; i < 30; i++ {
            ncSrvLogs, _ := getLogStreamEvents(log_group, log_stream)
            if strings.Contains(ncSrvLogs, "Hello from client") {
                found = true
                break
            }
            time.Sleep(10 * time.Second)
        }
        assert.True(t, found, "Expected 'Hello from client' in log stream within 5 minutes")
    }

}
