#!/usr/bin/env python3
"""Validate every production proof recipe and its required reader/tool inputs."""
import json
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE / "lib"))
import proof_evidence as evidence


class ProductionQualification(unittest.TestCase):
    def test_production_recipes_reject_known_shared_and_fixture_tool_omissions(self):
        root = HERE.parents[2]
        checks = json.loads((HERE / "proof-inputs.json").read_text())["checks"]
        for label, recipe in checks.items():
            with self.subTest(label=label):
                evidence.qualify_recipe(root, recipe)
                if recipe.get('subset'):
                    for field, values in recipe['subset'].items():
                        for value in values:
                            broken = {**recipe, 'subset': {**recipe['subset'],
                                field: [p for p in values if p != value]}}
                            with self.assertRaisesRegex(ValueError, 'subset qualification omits ' + field):
                                evidence.qualify_recipe(root, broken)
                if recipe.get('isolation'):
                    with self.assertRaisesRegex(ValueError, 'requires isolation'):
                        evidence.qualify_recipe(root, {k: v for k, v in recipe.items() if k != 'isolation'})
                if recipe.get('qualification_unit'):
                    contract = json.loads((root / recipe['qualification']).read_text())['units'][recipe['qualification_unit']]
                    for tool in contract['requires']['tools']:
                        with self.assertRaisesRegex(ValueError, 'qualification omits tools'):
                            evidence.qualify_recipe(root, {**recipe, 'tools': [t for t in recipe['tools'] if t != tool]})
                    if contract.get('external_paths'):
                        with self.assertRaisesRegex(ValueError, 'omits external_paths'):
                            evidence.qualify_recipe(root, {**recipe, 'external_paths': []})
                    for kind in contract.get('git_inputs', {}):
                        broken = {**recipe, 'git_inputs': {**recipe['git_inputs'], kind: []}}
                        with self.assertRaisesRegex(ValueError, 'omits git_inputs ' + kind):
                            evidence.qualify_recipe(root, broken)
                    for field in ('paths', 'external', 'environment'):
                        for value in contract['requires'][field]:
                            with self.assertRaisesRegex(ValueError, 'qualification omits ' + field):
                                evidence.qualify_recipe(root, {**recipe, field: [v for v in recipe[field] if v != value]})
                for tool in ("seq", "tee", "rmdir", "ln", "basename"):
                    broken = {**recipe, "tools": [name for name in recipe["tools"] if name != tool]}
                    with self.assertRaisesRegex(ValueError, "qualification omits tools: " + tool):
                        evidence.recipe_identity(root, broken, {})


if __name__ == "__main__":
    unittest.main()
