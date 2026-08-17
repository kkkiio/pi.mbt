"""Harbor adapter for pim, the MoonBit reimplementation of the pi coding agent.

pim is a self-contained native binary built by CI on the runner, so install
uploads the binary instead of installing a package. The provider credential
arrives via DEEPSEEK_API_KEY and is injected only into the agent process env.
"""

import shlex
from pathlib import Path
from typing import override

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext


class Pim(BaseInstalledAgent):
    """Run a pre-built pim binary inside the task environment."""

    _OUTPUT_FILENAME = "pim.txt"
    _REMOTE_BINARY = "/usr/local/bin/pim"
    _SUPPORTS_MODEL = "deepseek/deepseek-v4-flash"

    @staticmethod
    @override
    def name() -> str:
        return "pim"

    @override
    async def install(self, environment: BaseEnvironment) -> None:
        binary_value = self._get_env("PIM_BINARY")
        if not binary_value:
            raise ValueError("Set PIM_BINARY to the host-side pim binary path")
        binary_path = Path(binary_value).expanduser().resolve()
        if not binary_path.is_file():
            raise FileNotFoundError(
                f"PIM_BINARY must be a readable file: {binary_path}"
            )

        await environment.upload_file(binary_path, self._REMOTE_BINARY)
        chown = ""
        if environment.default_user is not None:
            chown = f"chown {shlex.quote(str(environment.default_user))} "
        await self.exec_as_root(
            environment,
            command=(
                f"{chown}{shlex.quote(self._REMOTE_BINARY)} && "
                f"chmod 755 {shlex.quote(self._REMOTE_BINARY)}"
            ),
        )

    @override
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        if self.model_name != self._SUPPORTS_MODEL:
            raise ValueError(
                f"pim currently supports only {self._SUPPORTS_MODEL}, "
                f"got {self.model_name!r}"
            )
        api_key = self._get_env("DEEPSEEK_API_KEY")
        if not api_key:
            raise ValueError("Pass DEEPSEEK_API_KEY via --ae")

        await self.exec_as_agent(
            environment,
            command=(
                "pim --session-dir /logs/agent/pim/sessions "
                f"--print {shlex.quote(instruction)} "
                f"2>&1 </dev/null | stdbuf -oL tee /logs/agent/{self._OUTPUT_FILENAME}"
            ),
            env={"DEEPSEEK_API_KEY": api_key},
        )
