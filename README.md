# phpipam-sync-dhcp
Sync Windows DHCP server leases/reservations into PHPIPAM

# Tested with the following versions:

 - PHPIPAM 1.4.7 
 - PSPHPIPAM 1.3.8 
 - Windows Server 2022 core with DHCP role installed 
 - Powershell 5.1 and Powershell core see notes in the file
   itself about certain cmdlets.

Make sure all the DHCP scopes **already exists** in PHPIPAM.
This script **does not create** the DHCP scopes as new subnets in PHPIPAM.

We run this script hourly with Azure Automate with a hybrid run as account worker.
