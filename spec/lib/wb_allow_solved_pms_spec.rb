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

    it "resolves the dirty values live sites hold, without emitting everyone (B3)" do
      # Why the plugin resolves group_list itself instead of using the stock _map helper:
      # _map is split("|").map(&:to_i), and "support".to_i == 0 -- the `everyone` group.
      # Production really does hold values like this: 0.2.0 shipped group *names* as
      # settings.yml defaults, so they sit in the stored value verbatim next to real ids.
      #
      # The dirty value is passed in literally rather than through SiteSetting=: newer core
      # normalises names to ids on assignment, so assigning one cannot reproduce the trap --
      # and asserting _map's own behaviour here would only pin this spec to a core version.
      dirty = "support|#{agents.id}"

      expect(described_class.group_ids_from_setting(dirty)).to contain_exactly(
        support.id,
        agents.id,
      )
      expect(described_class.group_ids_from_setting(dirty)).not_to include(
        Group::AUTO_GROUPS[:everyone],
      )
    end
  end
end
