package terraform

# OPA allows you to overload functions https://www.openpolicyagent.org/docs/latest/policy-language/#incremental-definitions
# This is how we can create functions to extract a value, but fall back to a default value if it's missing
get_resource_key(resource, _default) = key {
  not resource.index
  key := _default
}
get_resource_key(resource, _default) = key {
  key := resource.index
}

get_resource_id(resource, _default) = id {
  not resource.change.before.id
  id := _default
}
get_resource_id(resource, _default) = id {
  id := resource.change.before.id
}

deletion_violations[output] {                                 # a resource violates deletion rules if...
  resource := input.resource_changes[_]                       # it's in the change plan and...
  resource.change.actions[_] == "delete"                      # it's actions include "delete" and ...
  glob.match(data.do_not_delete[_], [":"], resource.address)  # it's resource.address is a glob match to something in the do_not_delete list
  output := {                                                 # so build an output object with all the resource data
    "resource_name": resource.name,
    "resource_type": resource.type,
    "resource_key": get_resource_key(resource, ""),
    "resource_id": get_resource_id(resource, "")
  }
}