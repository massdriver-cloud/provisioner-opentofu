package deletion_protection

# Standard policies interface - all policy files should export policy violations under this name
violations contains violation if {
  violation := deletion_protection[_]
}

deletion_protection contains violation if {                   # a resource violates deletion protection if...
  resource := input.resource_changes[_]                       # it's in the change plan and...
  resource.change.actions[_] == "delete"                      # it's actions include "delete" and ...
  glob.match(data.do_not_delete[_], [":"], resource.address)  # it's resource.address is a glob match to something in the do_not_delete list
  violation := {                                              # so build an result object with all the resource data
    "message": sprintf("Resource %s.%s is protected from deletion", [
      resource.type,
      resource.name
    ])
  }
}