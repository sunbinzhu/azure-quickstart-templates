<##################################################################################################

    Usage Example
    =============

    Login-AzureRmAccount
    Import-Module .\Cmdlets.DevTestLab.ps1
    Get-AzureDtlLab   


    Help / Documentation
    ====================
    - To view a cmdlet's help description: Get-help "cmdlet-name" -Detailed
    - To view a cmdlet's usage example: Get-help "cmdlet-name" -Examples


    Pre-Requisites
    ==============
    - Please ensure that the powershell execution policy is set to unrestricted or bypass.
    - Please ensure that the latest version of Azure Powershell in installed on the machine.


    Known Issues
    ============
    - The following regression in the Azure PS cmdlets impacts us currently. 
      - https://github.com/Azure/azure-powershell/issues/1259

##################################################################################################>

#
# Configurations
#

# Resource types exposed by the DevTestLab provider.
$LabResourceType = "microsoft.devtestlab/labs"
$EnvironmentResourceType = "microsoft.devtestlab/environments"
$VMTemplateResourceType = "microsoft.devtestlab/labs/vmtemplates"

# The API version required to query DTL resources
$RequiredApiVersion = "2015-05-21-preview"

##################################################################################################

#
# Private helper methods
#

function GetLabFromVM_Private
{
    Param(
        [ValidateNotNull()]
        # An existing VM (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $VM
    )

    $vmProperties = Get-AzureRmResource -ExpandProperties | Where {
        $_.ResourceType -eq $EnvironmentResourceType -and 
        $_.ResourceId -eq $VM.ResourceId
    } | Select -Property "Properties"

    Get-AzureRmResource | Where {
        $_.ResourceType -eq $LabResourceType -and 
        $_.ResourceId -eq $vmProperties.Properties.LabId
    }
}

function GetResourceWithProperties_Private
{
    Param(
        [ValidateNotNull()]
        # ResourceId of an existing Azure RM resource.
        $Resource
    )

    if ($null -eq $Resource.Properties)
    {
        Get-AzureRmResource -ExpandProperties -ResourceId $Resource.ResourceId -ApiVersion $RequiredApiVersion
    }
    else
    {
        return $Resource
    }
}

function CreateNewResourceGroup_Private
{
    Param(
        [ValidateNotNullOrEmpty()]
        [string]
        # Seed/Prefix for the new resource group name to be generated.
        $ResourceGroupSeedPrefixName,

        [ValidateNotNullOrEmpty()]
        [string]
        # Location where the new resource group will be generated.
        $Location
    )

    # Using the seed/prefix, we'll generate a unique random name for the resource group.
    # We'll then check if there is an existing resource group with the same name.
    do
    {
        # NOTE: Unfortunately the Get-AzureRmResourceGroup cmdlet throws a terminating error 
        # if the specified resource group name does not exist. So we'll use a try/catch block.
        try
        {
            $randomRGName = $($ResourceGroupSeedPrefixName + (Get-Random).ToString())
            $randomRG = Get-AzureRmResourceGroup -Name $randomRGName
        }
        catch [ArgumentException]
        {
            $randomRG = $null
        }
    }
    until ($null -eq $randomRG)

    return (New-AzureRmResourceGroup -Name $randomRGName -Location $Location)
}

##################################################################################################

function Get-AzureDtlLab
{
    <#
        .SYNOPSIS
        Gets labs under the current subscription.

        .DESCRIPTION
        The Get-AzureDtlLab cmdlet does the following: 
        - Gets a specific lab, if the -LabId parameter is specified.
        - Gets all labs with matching name, if the -LabName parameter is specified.
        - Gets all labs with matching name within a resource group, if the -LabName and -LabResourceGroupName parameters are specified.
        - Gets all labs in a resource group, if the -LabResourceGroupName parameter is specified.
        - Gets all labs in a location, if the -LabLocation parameter is specified.
        - Gets all labs within current subscription, if no parameters are specified. 

        .EXAMPLE
        Get-AzureDtlLab -LabId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab"
        Gets a specific lab, identified by the specified resource-id.

        .EXAMPLE
        Get-AzureDtlLab -LabName "MyLab"
        Gets all labs with the name "MyLab".

        .EXAMPLE
        Get-AzureDtlLab -LabName "MyLab" -LabResourceGroupName "MyLabRG"
        Gets all labs with the name "MyLab" within the resource group "MyLabRG".

        .EXAMPLE
        Get-AzureDtlLab -LabResourceGroupName "MyLabRG"
        Gets all labs in the "MyLabRG" resource group.

        .EXAMPLE
        Get-AzureDtlLab -LabLocation "westus"
        Gets all labs in the "westus" location.

        .EXAMPLE
        Get-AzureDtlLab
        Gets all labs within current subscription (use the Select-AzureRmSubscription cmdlet to change the current subscription).

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="ListAll")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="ListByLabId")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The ResourceId of the lab (e.g. "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab").
        $LabId,

        [Parameter(Mandatory=$true, ParameterSetName="ListByLabName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the lab.
        $LabName,

        [Parameter(Mandatory=$false, ParameterSetName="ListByLabName")] 
        [Parameter(Mandatory=$true, ParameterSetName="ListAllInResourceGroup")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the lab's resource group.
        $LabResourceGroupName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLocation")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The location of the lab ("westus", "eastasia" etc).
        $LabLocation
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        switch($PSCmdlet.ParameterSetName)
        {
            "ListByLabId"
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $LabResourceType -and 
                    $_.ResourceId -eq $LabId 
                } | Write-Output
            }
                    
            "ListByLabName"
            {
                if ($PSBoundParameters.ContainsKey("LabResourceGroupName"))
                {
                    Get-AzureRmResource | Where { 
                        $_.ResourceType -eq $LabResourceType -and 
                        $_.ResourceName -eq $LabName -and 
                        $_.ResourceGroupName -eq $LabResourceGroupName 
                    } | Write-Output                
                }
                else
                {
                    Get-AzureRmResource | Where { 
                        $_.ResourceType -eq $LabResourceType -and 
                        $_.ResourceName -eq $LabName 
                    }                 
                }
            }

            "ListAllInResourceGroup"
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $LabResourceType -and 
                    $_.ResourceGroupName -eq $LabResourceGroupName 
                } | Write-Output
            }

            "ListAllInLocation"
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $LabResourceType -and 
                    $_.Location -eq $LabLocation 
                } | Write-Output
            }

            "ListAll" 
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $LabResourceType 
                } | Write-Output
            }
        }
    }
}

##################################################################################################

function Get-AzureDtlVMTemplate
{
    <#
        .SYNOPSIS
        Gets VM templates from a specified lab.

        .DESCRIPTION
        The Get-AzureDtlVMTemplate cmdlet does the following: 
        - Gets a specific VM template, if the -VMTemplateId parameter is specified.
        - Gets all VM templates with matching name from a lab, if the -VMTemplateName and -Lab parameters are specified.
        - Gets all VM templates from a lab, if the -Lab parameter is specified.

        .EXAMPLE
        Get-AzureDtlVMTemplate -VMTemplateId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab1/vmtemplates/MyVMTemplate1"
        Gets a specific VM template, identified by the specified resource-id.

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab1"
        Get-AzureDtlVMTemplate -VMTemplateName "MyVMTemplate1" -Lab $lab

        Gets all VM templates with the name "MyVMTemplate1" from the lab "MyLab1".

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab1"
        Get-AzureDtlVMTemplate -Lab $lab

        Gets all VM templates from the lab "MyLab1".

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="ListAllInLab")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="ListByVMTemplateId")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The ResourceId of the VM template (e.g. "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/labs/MyLab1/vmtemplates/MyVMTemplate1").
        $VMTemplateId,

        [Parameter(Mandatory=$true, ParameterSetName="ListByVMTemplateName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM template 
        $VMTemplateName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLab")] 
        [Parameter(Mandatory=$true, ParameterSetName="ListByVMTemplateName")] 
        [ValidateNotNull()]
        # An existing lab (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $Lab
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        switch ($PSCmdlet.ParameterSetName)
        {
            "ListByVMTemplateId"
            {
                Get-AzureRmResource -ResourceId $VMTemplateId -ApiVersion $RequiredApiVersion | Write-Output
            }

            "ListByVMTemplateName"
            {
                Get-AzureRmResource -ResourceName $Lab.ResourceName -ResourceGroupName $Lab.ResourceGroupName -ResourceType $VMTemplateResourceType -ApiVersion $RequiredApiVersion | Where {
                    $_.Name -eq $VMTemplateName
                } | Write-Output
            }

            "ListAllInLab"
            {
                Get-AzureRmResource -ResourceName $Lab.ResourceName -ResourceGroupName $Lab.ResourceGroupName -ResourceType $VMTemplateResourceType -ApiVersion $RequiredApiVersion | Write-Output
            }
        }
    }
}

##################################################################################################

function Get-AzureDtlVirtualMachine
{
    <#
        .SYNOPSIS
        Gets virtual machines under the current subscription.

        .DESCRIPTION
        The Get-AzureDtlVirtualMachine cmdlet does the following: 
        - Gets a specific VM, if the -VMId parameter is specified.
        - Gets all VMs with matching name, if the -VMName parameter is specified.
        - Gets all VMs in a lab, if the -LabName parameter is specified.
        - Gets all VMs in a resource group, if the -VMResourceGroup parameter is specified.
        - Gets all VMs in a location, if the -VMLocation parameter is specified.
        - Gets all VMs within current subscription, if no parameters are specified. 

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/environments/MyVM"
        Gets a specific VM, identified by the specified resource-id.

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMName "MyVM1"
        Gets all VMs with the name "MyVM1".

        .EXAMPLE
        Get-AzureDtlVirtualMachine -LabName "MyLab"
        Gets all VMs within the lab "MyLab".

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMResourceGroupName "MyLabRG"
        Gets all VMs in the "MyLabRG" resource group.

        .EXAMPLE
        Get-AzureDtlVirtualMachine -VMLocation "westus"
        Gets all VMs in the "westus" location.

        .EXAMPLE
        Get-AzureDtlVirtualMachine
        Gets all VMs within current subscription (use the Select-AzureRmSubscription cmdlet to change the current subscription).

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="ListAll")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="ListByVMId")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The ResourceId of the VM (e.g. "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/MyLabRG/providers/Microsoft.DevTestLab/environments/MyVM").
        $VMId,

        [Parameter(Mandatory=$true, ParameterSetName="ListByVMName")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM.
        $VMName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLab")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Name of the lab.
        $LabName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInResourceGroup")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of the VM's resource group.
        $VMResourceGroupName,

        [Parameter(Mandatory=$true, ParameterSetName="ListAllInLocation")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The location of the VM.
        $VMLocation
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        switch($PSCmdlet.ParameterSetName)
        {
            "ListByVMId"
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.ResourceId -eq $VMId 
                } | Write-Output
            }
                    
            "ListByVMName"
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.ResourceName -eq $VMName 
                } | Write-Output                
            }

            "ListAllInLab"
            {
                $fetchedLabObj = Get-AzureDtlLab -LabName $LabName 

                if ($fetchedLabObj -ne $null -and $fetchedLabObj.Count -ne 0)
                {
                    if ($fetchedLabObj.Count > 1)
                    {
                        throw $("Multiple labs found with name '" + $LabName + "'")
                    }
                    else
                    {
                        write-Verbose $("Found lab : " + $fetchedLabObj.ResourceName) 
                        write-Verbose $("LabId : " + $fetchedLabObj.ResourceId) 

                        # Note: The -ErrorAction 'SilentlyContinue' ensures that we suppress irrelevant
                        # errors originating while expanding properties (especially in internal test and
                        # pre-production subscriptions).
                        Get-AzureRmResource -ExpandProperties -ErrorAction "SilentlyContinue" | Where { 
                            $_.ResourceType -eq $EnvironmentResourceType -and
                            $_.Properties.LabId -eq $fetchedLabObj.ResourceId
                        } | Write-Output
                    }
                }
            }

            "ListAllInResourceGroup"
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.ResourceGroupName -eq $VMResourceGroupName 
                } | Write-Output                
            }

            "ListAllInLocation"
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $EnvironmentResourceType -and 
                    $_.Location -eq $VMLocation 
                } | Write-Output
            }

            "ListAll" 
            {
                Get-AzureRmResource | Where { 
                    $_.ResourceType -eq $EnvironmentResourceType 
                } | Write-Output 
            }
        }
    }
}

##################################################################################################

function New-AzureDtlLab
{
    <#
        .SYNOPSIS
        Creates a new lab.

        .DESCRIPTION
        The New-AzureDtlLab cmdlet creates a new lab in the specified location.

        .EXAMPLE
        New-AzureDtlLab -LabName "MyLab1" -LabLocation "West US"
        Creates a new lab "MyLab1" in the location "West US".

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Name of lab to be created.
        $LabName,

        [Parameter(Mandatory=$true)] 
        [ValidateNotNullOrEmpty()]
        [string]
        # Location where the lab will be created.
        $LabLocation
    )

    PROCESS 
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # Unique name for the deployment
        $deploymentName = [Guid]::NewGuid().ToString()

        # Folder location of VM creation script, the template file and template parameters file.
        $LabCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "azuredeploy.json"

        # Pre-condition check to ensure the RM template file exists.
        if ($false -eq (Test-Path -Path $LabCreationTemplateFile))
        {
            throw $("The RM template file could not be located at : '" + $LabCreationTemplateFile + "'")
        }
        else
        {
            Write-Verbose $("The RM template file was located at : '" + $LabCreationTemplateFile + "'")
        }

        # Check if there are any existing labs with same name in the current subscription
        $existingLabs = Get-AzureRmResource | Where { 
            $_.ResourceType -eq $LabResourceType -and 
            $_.ResourceName -eq $LabName -and 
            $_.SubscriptionId -eq (Get-AzureRmContext).Subscription.SubscriptionId
        }

        # If none exist, then create a new one
        if ($null -eq $existingLabs -or 0 -eq $existingLabs.Count)
        {
            # Create a new resource group with a unique name (using the lab name as a seed/prefix).
            Write-Verbose $("Creating new resoure group with seed/prefix '" + $LabName + "' at location '" + $LabLocation + "'")
            $newResourceGroup = CreateNewResourceGroup_Private -ResourceGroupSeedPrefixName $LabName -Location $LabLocation
            Write-Verbose $("Created new resoure group '" + $newResourceGroup.ResourceGroupName + "' at location '" + $newResourceGroup.Location + "'")
    
            # Create the lab in this resource group by deploying the RM template
            Write-Verbose $("Creating new lab '" + $LabName + "'")
            $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName  -TemplateFile $LabCreationTemplateFile -newLabName $LabName 

            if (($null -ne $rgDeployment) -and ($null -ne $rgDeployment.Outputs['labId']) -and ($null -ne $rgDeployment.Outputs['labId'].Value))
            {
                $labId = $rgDeployment.Outputs['labId'].Value

                Write-Verbose $("LabId : '" + $labId + "'")

                Get-AzureRmResource -ResourceId $labId | Write-Output
            }
        }

        # else display an error
        else
        {
            throw $("One or more labs with name '" + $LabName + "' already exist in the current subscription '" + (Get-AzureRmContext).Subscription.SubscriptionId + "'.")
        }
    }
}

##################################################################################################

function New-AzureDtlVMTemplate
{
    <#
        .SYNOPSIS
        Creates a new (or updates an existing) virtual machine template.

        .DESCRIPTION
        The New-AzureDtlVMTemplate cmdlet creates a new VM template from an existing VM.
        - The new VM template is created in the same lab as the VM.
        - If a VM template with the same name already exists in the lab, then it simply updates it.

        .EXAMPLE
        $lab = $null

        $vm = Get-AzureDtlVirtualMachine -VMName "MyVM1"
        New-AzureDtlVMTemplate -VM $vm -VMTemplateName "MyVMTemplate1" -VMTemplateDescription "MyDescription"

        Creates a new VM Template "MyVMTemplate1" from the VM "MyVM1".

        .INPUTS
        None.
    #>
    [CmdletBinding()]
    Param(
        [ValidateNotNull()]
        # An existing VM from which the new VM template will be created (please use the Get-AzureDtlVirtualMachine cmdlet to get this lab object).
        $VM,

        [ValidateNotNullOrEmpty()]
        [string]
        # Name of the new VM template to create.
        $VMTemplateName,

        [ValidateNotNull()]
        [string]
        # Details about the new VM template being created.
        $VMTemplateDescription = ""
    )

    PROCESS
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # Unique name for the deployment
        $deploymentName = [Guid]::NewGuid().ToString()

        # Folder location of VM creation script, the template file and template parameters file.
        $VMTemplateCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\201-dtl-create-vmtemplate\azuredeploy.json" -Resolve

        # Pre-condition check to ensure the RM template file exists.
        if ($false -eq (Test-Path -Path $VMTemplateCreationTemplateFile))
        {
            throw $("The RM template file could not be located at : '" + $VMTemplateCreationTemplateFile + "'")
        }
        else
        {
            Write-Verbose $("The RM template file was located at : '" + $VMTemplateCreationTemplateFile + "'")
        }

        # Get the lab that contains the source VM
        $lab = GetLabFromVM_Private -VM $VM

        if ($null -eq $lab)
        {
            throw $("Unable to detect lab for VM '" + $VM.ResourceName + "'")
        }
        else
        {
            # encode the VM template name
            $VMTemplateNameEncoded = $VMTemplateName.Replace(" ", "%20")

            # Create the VM Template in the lab's resource group by deploying the RM template
            Write-Verbose $("Creating VM Template '" + $VMTemplateName + "' in lab '" + $lab.ResourceName + "'")
            $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $lab.ResourceGroupName -TemplateFile $VMTemplateCreationTemplateFile -existingLabName $lab.ResourceName -existingVMResourceId $VM.ResourceId -templateName $VMTemplateNameEncoded -templateDescription $VMTemplateDescription

            if (($null -ne $rgDeployment) -and ($null -ne $rgDeployment.Outputs['vmTemplateId']) -and ($null -ne $rgDeployment.Outputs['vmTemplateId'].Value))
            {
                $vmTemplateId = $rgDeployment.Outputs['vmTemplateId'].Value

                Write-Verbose $("VMTemplateId : '" + $vmTemplateId + "'")

                Get-AzureRmResource -ResourceId $vmTemplateId -ApiVersion $RequiredApiVersion | Write-Output
            }
        }
    }
}

##################################################################################################

function New-AzureDtlVirtualMachine
{
    <#
        .SYNOPSIS
        Creates a new virtual machine.

        .DESCRIPTION
        The New-AzureDtlVirtualMachine cmdlet creates a new VM in a lab (and optionally creates a user account on the VM).

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $vmtemplate = Get-AzureDtlVMTemplate -Lab $lab -VMTemplateName "MyVMTemplate"
        New-AzureDtlVirtualMachine -VMName "MyVM" -VMSize "Standard_A4" -Lab $lab -VMTemplate $vmtemplate

        Creates a new VM "MyVM" from the VM template "MyVMTemplate" in the lab "MyLab".
        - No new user account is created during the VM creation.
        - We assume that the original VM template already contains a built-in user account.
        - We assume that this built-in account can be used to log into the VM after creation.

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $vmtemplate = Get-AzureDtlVMTemplate -Lab $lab -VMTemplateName "MyVMTemplate"
        $secPwd = ConvertTo-SecureString -String "MyPwd" -AsPlainText -Force
        New-AzureDtlVirtualMachine -VMName "MyVM" -VMSize "Standard_A4" -Lab $lab -VMTemplate $vmtemplate -UserName "MyAdmin" -Password $secPwd

        Creates a new VM "MyVM" from the VM template "MyVMTemplate" in the lab "MyLab".
        - A new user account is created using the username/password combination specified.
        - This user account is added to the local administrators group. 

        .EXAMPLE
        $lab = $null

        $lab = Get-AzureDtlLab -LabName "MyLab"
        $vmtemplate = Get-AzureDtlVMTemplate -Lab $lab -VMTemplateName "MyVMTemplate"
        $sshKey = ConvertTo-SecureString -String "MyKey" -AsPlainText -Force
        New-AzureDtlVirtualMachine -VMName "MyVM" -VMSize "Standard_A4" -Lab $lab -VMTemplate $vmtemplate -UserName "MyAdmin" -SSHKey $sshKey

        Creates a new VM "MyVM" from the VM template "MyVMTemplate" in the lab "MyLab".
        - A new user account is created using the username/SSH-key combination specified.

        .INPUTS
        None. Currently you cannot pipe objects to this cmdlet (this will be fixed in a future version).  
    #>
    [CmdletBinding(DefaultParameterSetName="BuiltInUser")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The name of VM to be created.
        $VMName,

        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The size of VM to be created ("Standard_A0", "Standard_D1_v2", "Standard_D2" etc).
        $VMSize,

        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNull()]
        # An existing lab in which the VM will be created (please use the Get-AzureDtlLab cmdlet to get this lab object).
        $Lab,

        [Parameter(Mandatory=$true, ParameterSetName="BuiltInUser")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNull()]
        # An existing VM template which will be used to create the new VM (please use the Get-AzureDtlVmTemplate cmdlet to get this VMTemplate object).
        # Note: This VM template must exist in the lab identified via the '-LabName' parameter.
        $VMTemplate,

        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [string]
        # The user name that will be created on the new VM.
        $UserName,

        [Parameter(Mandatory=$true, ParameterSetName="UsernamePwd")] 
        [ValidateNotNullOrEmpty()]
        [Security.SecureString]
        # The password for the user to be created.
        $Password,

        [Parameter(Mandatory=$true, ParameterSetName="UsernameSSHKey")] 
        [ValidateNotNullOrEmpty()]
        [Security.SecureString]
        # The public SSH key for user to be created.
        $SSHKey
    )

    PROCESS 
    {
        Write-Verbose $("Processing cmdlet '" + $PSCmdlet.MyInvocation.InvocationName + "', ParameterSet = '" + $PSCmdlet.ParameterSetName + "'")

        # Get the same VM template object, but with properties attached.
        $VMTemplate = GetResourceWithProperties_Private -Resource $VMTemplate

        if ("Gallery" -eq $VMTemplate.Properties.ImageType)
        {
            if ($false -eq (($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("Password")) -or ($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("SSHKey"))))
            {
                throw $("The specified VM template '" + $VMTemplate.Name + "' uses an Azure gallery image. Please specify either the -UserName and -Password parameters or the -UserName and -SSHKey parameters to use this VM template.")
            }
        }
        else
        {
            # Pre-condition checks for linux VHDs.
            if ("linux" -eq $VMTemplate.Properties.OsType)
            {
                if ($false -eq (($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("Password")) -or ($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("SSHKey"))))
                {
                    throw $("The specified VM template '" + $VMTemplate.Name + "' uses a linux VHD. Please specify either the -UserName and -Password parameters or the -UserName and -SSHKey parameters to use this VM template.")
                }
            }

            # Pre-condition checks for sysprepped VHDs.
            if ($true -eq $VMTemplate.Properties.SysPrep)
            {
                if ($false -eq ($PSBoundParameters.ContainsKey("UserName") -and $PSBoundParameters.ContainsKey("Password")))
                {
                    throw $("The specified VM template '" + $VMTemplate.Name + "' uses a sysprepped VHD. Please specify both the -UserName and -Password parameters to use this VM template.")
                }
            }
        }


        # Folder location of VM creation script, the template file and template parameters file.
        $VMCreationTemplateFile = $null

        switch($PSCmdlet.ParameterSetName)
        {
            "BuiltInUser"
            {
                $VMCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\101-dtl-create-vm-builtin-user\azuredeploy.json" -Resolve
            }

            "UsernamePwd"
            {
                $VMCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\101-dtl-create-vm-username-pwd\azuredeploy.json" -Resolve
            }

            "UsernameSSHKey"
            {
                $VMCreationTemplateFile = Join-Path $PSScriptRoot -ChildPath "..\101-dtl-create-vm-username-ssh\azuredeploy.json" -Resolve
            }
        }

        # pre-condition check to ensure that the template file actually exists.
        if ($false -eq (Test-Path -Path $VMCreationTemplateFile))
        {
            Write-Error $("The RM template file could not be located at : '" + $VMCreationTemplateFile + "'")
        }
        else
        {
            Write-Verbose $("The RM template file was located at : '" + $VMCreationTemplateFile + "'")
        }


        # Create a new resource group with a unique name (using the VM name as a seed/prefix).
        Write-Verbose $("Creating new resoure group with seed/prefix '" + $VMName + "' at location '" + $Lab.Location + "'")
        $newResourceGroup = CreateNewResourceGroup_Private -ResourceGroupSeedPrefixName $VMName -Location $Lab.Location
        Write-Verbose $("Created new resource group '" + $newResourceGroup.ResourceGroupName + "' at location '" + $newResourceGroup.Location + "'")

        # Create the virtual machine in this lab by deploying the RM template
        Write-Verbose $("Creating new virtual machine '" + $VMName + "'")
        Write-Warning $("Creating new virtual machine '" + $VMName + "'. This may take a couple of minutes.")

        $rgDeployment = $null

        # Unique name for the deployment
        $deploymentName = [Guid]::NewGuid().ToString()

        switch($PSCmdlet.ParameterSetName)
        {
            "BuiltInUser"
            {
                $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName -TemplateFile $VMCreationTemplateFile -newVMName $VMName -existingLabName $Lab.ResourceName -existingLabResourceGroupName $Lab.ResourceGroupName -newVMSize $VMSize -existingVMTemplateName $VMTemplate.Name
            }

            "UsernamePwd"
            {
                $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName -TemplateFile $VMCreationTemplateFile -newVMName $VMName -existingLabName $Lab.ResourceName -existingLabResourceGroupName $Lab.ResourceGroupName -newVMSize $VMSize -existingVMTemplateName $VMTemplate.Name -userName $UserName -password $Password
            }

            "UsernameSSHKey"
            {
                $rgDeployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $newResourceGroup.ResourceGroupName -TemplateFile $VMCreationTemplateFile -newVMName $VMName -existingLabName $Lab.ResourceName -existingLabResourceGroupName $Lab.ResourceGroupName -newVMSize $VMSize -existingVMTemplateName $VMTemplate.Name -userName $UserName -sshKey $SSHKey  
            }
        }

        if (($null -ne $rgDeployment) -and ($null -ne $rgDeployment.Outputs['vmId']) -and ($null -ne $rgDeployment.Outputs['vmId'].Value))
        {
            Write-Verbose $("vm id : '" + $rgDeployment.Outputs['vmId'].Value + "'")

            Get-AzureRmResource -ResourceId $rgDeployment.Outputs['vmId'].Value | Write-Output
        }
    }
}

##################################################################################################

