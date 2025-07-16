# Roblox Project Template
This is the default project template for my Roblox coding setup, including **Rojo**,
**Selene**, **Stylua**, and **Luau Language Server** setup (not Luau Language Server settings).

## Template Features
The main feature of this template is that it allows for proper mapping to the
Roblox services typically used to store scripts without worrying about removal of
assets already within those scripts by use of `"$ignoreUnknownInstances": true`
within the /default.project.json file. *Note: You should ideally still create a
/Source or /src folder within each of these services for storing scripts to keep
a proper structure that separates assets from source code containing scripts.

Stylua has an included toml file to arrange required modules in alphabetical order,
similar to how services are when auto-imported. 

/OtherScripts is an included folder where I often create or place test scripts not
meant to sync through Rojo. This is also often added to my /.gitignore file but
is commented out by default.
