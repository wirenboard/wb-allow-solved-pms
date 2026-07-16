# frozen_string_literal: true

require "rails_helper"

describe WbAllowSolvedPms do
  describe ".group_ids_from_setting" do
    fab!(:support) { Fabricate(:group, name: "support") }
    fab!(:agents) { Fabricate(:group, name: "Support_Agents") }

    it "returns nothing when the setting is empty" do
      expect(described_class.group_ids_from_setting("")).to eq([])
      expect(described_class.group_ids_from_setting(nil)).to eq([])
      expect(described_class.group_ids_from_setting("|| |")).to eq([])
    end

    it "resolves the ids Discourse actually stores (B1)" do
      expect(described_class.group_ids_from_setting("#{support.id}|#{agents.id}")).to contain_exactly(
        support.id,
        agents.id,
      )
    end

    it "still resolves legacy group names, case-insensitively (B1 back-compat, B7)" do
      expect(described_class.group_ids_from_setting("support")).to eq([support.id])
      expect(described_class.group_ids_from_setting("SuPPoRt")).to eq([support.id])
      expect(described_class.group_ids_from_setting("support_agents")).to eq([agents.id])
    end

    it "resolves the mixed name/id values found on production" do
      expect(described_class.group_ids_from_setting("support|#{agents.id}")).to contain_exactly(
        support.id,
        agents.id,
      )
    end

    it "de-duplicates a group given both by name and by id" do
      expect(described_class.group_ids_from_setting("support|#{support.id}")).to eq([support.id])
    end

    it "drops unknown names rather than guessing" do
      expect(described_class.group_ids_from_setting("no_such_group")).to eq([])
      expect(described_class.group_ids_from_setting("no_such_group|support")).to eq([support.id])
    end

    it "never emits group 0 / everyone (B3)" do
      expect(described_class.group_ids_from_setting("0")).to eq([])
      expect(described_class.group_ids_from_setting("0|#{support.id}")).to eq([support.id])
    end

    it "avoids the SiteSetting#..._map trap that dirty values spring (B3)" do
      SiteSetting.solved_pm_actor_groups = "support|#{agents.id}"

      # Why the plugin cannot use the stock _map helper: it is split("|").map(&:to_i),
      # and "support".to_i == 0 -- which is the `everyone` group.
      expect(SiteSetting.solved_pm_actor_groups_map).to include(Group::AUTO_GROUPS[:everyone])

      expect(
        described_class.group_ids_from_setting(SiteSetting.solved_pm_actor_groups),
      ).to contain_exactly(support.id, agents.id)
    end
  end
end
