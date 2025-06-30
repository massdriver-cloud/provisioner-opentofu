package deletion_protection

# Standard policies interface - all policy files should export policies under this name
policies[policy] {
  policy := deletion_protection[_]
}

deletion_protection[result] {                                 # a resource violates deletion protection if...
  resource := input.resource_changes[_]                       # it's in the change plan and...
  resource.change.actions[_] == "delete"                      # it's actions include "delete" and ...
  glob.match(data.do_not_delete[_], [":"], resource.address)  # it's resource.address is a glob match to something in the do_not_delete list
  result := {                                                 # so build an result object with all the resource data
    "message": sprintf("Resource %s.%s is protected from deletion", [
      resource.type,
      resource.name
    ])
  }
}