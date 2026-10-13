#!/usr/bin/python

from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
        argument_spec={
            "kubectl": {"type": "path", "required": True},
            "kubeconfig": {"type": "path", "required": True},
            "filename": {"type": "path", "required": True},
            "state": {
                "type": "str",
                "choices": ["present", "latest", "absent"],
                "default": "present",
            },
        },
        supports_check_mode=True,
    )

    state = module.params["state"]
    action = "delete" if state == "absent" else "apply"
    command = [
        module.params["kubectl"],
        "--kubeconfig",
        module.params["kubeconfig"],
        action,
        "--filename",
        module.params["filename"],
    ]
    if state == "absent":
        command.append("--ignore-not-found=true")

    if module.check_mode:
        if state == "absent":
            command.append("--dry-run=server")
        else:
            command.extend(["--dry-run=server", "--output=name"])

    rc, stdout, stderr = module.run_command(command)
    if rc != 0:
        module.fail_json(
            msg="kubectl failed",
            command=command,
            rc=rc,
            stdout=stdout,
            stderr=stderr,
        )

    output_lines = [line for line in stdout.splitlines() if line.strip()]
    if state == "absent":
        changed = any("not found" not in line.lower() for line in output_lines)
    else:
        # Match Kubespray's kube module semantics: apply reconciles desired
        # state but does not make repeated controller-side updates noisy.
        changed = False
    module.exit_json(changed=changed, command=command, stdout=stdout)


if __name__ == "__main__":
    main()
