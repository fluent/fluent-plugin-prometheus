require 'logger'

require 'spec_helper'
require 'fluent/plugin/prometheus/placeholder_expander'
require_relative '../shared'

describe Fluent::Plugin::Prometheus::ExpandBuilder::PlaceholderExpander do
  let(:log) do
    Logger.new('/dev/null')
  end

  let(:builder) do
    Fluent::Plugin::Prometheus::ExpandBuilder.new(log: log)
  end

  describe '#expand' do
    context 'with static placeholder' do
      let(:static_placeholder) do
        {
          'hostname' => 'host_value',
          'tag' => '1.2.3',
          'ary_value' => ['1', '2', '3'],
          'hash_value' => { 'key1' => 'val1' },
        }
      end

      let(:dynamic_placeholder) do
      end

      it 'expands values' do
        expander = builder.build(static_placeholder)
        expect(expander.expand('${hostname}')).to eq('host_value')
        expect(expander.expand('${ary_value[0]}.${ary_value[1]}.${ary_value[2]}')).to eq('1.2.3')
        expect(expander.expand('${ary_value[-3]}.${ary_value[-2]}.${ary_value[-1]}')).to eq('1.2.3')
        expect(expander.expand('${hash_value["key1"]}')).to eq('val1')

        expect(expander.expand('${tag}')).to eq('1.2.3')
        expect(expander.expand('${tag_parts[0]}.${tag_parts[1]}.${tag_parts[2]}')).to eq('1.2.3')
        expect(expander.expand('${tag_parts[-3]}.${tag_parts[-2]}.${tag_parts[-1]}')).to eq('1.2.3')
        expect(expander.expand('${tag_prefix[0]}.${tag_prefix[1]}.${tag_prefix[2]}')).to eq('1.1.2.1.2.3')
        expect(expander.expand('${tag_suffix[0]}.${tag_suffix[1]}.${tag_suffix[2]}')).to eq('3.2.3.1.2.3')
      end

      it 'does not create new expander' do
        builder # cached before mock

        expect(Fluent::Plugin::Prometheus::ExpandBuilder).to receive(:build).with(anything, log: anything).never
        expander = builder.build(static_placeholder)
        expander.expand('${hostname}')
        expander.expand('${hostname}')
      end

      # tag_parts, tag_prefix and tag_suffix must be expanded with the tag,
      # not with "forged"
      context 'with a value named after a tag placeholder' do
        let(:forged_placeholder) do
          {
            'tag' => '1.2.3',
            'tag_parts' => %w[forged forged forged],
            'tag_prefix' => %w[forged forged forged],
            'tag_suffix' => %w[forged forged forged],
          }
        end

        it 'expands the placeholders with the tag' do
          expander = builder.build(forged_placeholder)

          expect(expander.expand('${tag_parts[0]}.${tag_parts[1]}.${tag_parts[2]}')).to eq('1.2.3')
          expect(expander.expand('${tag_parts[-3]}.${tag_parts[-2]}.${tag_parts[-1]}')).to eq('1.2.3')
          expect(expander.expand('${tag_prefix[0]},${tag_prefix[1]},${tag_prefix[2]}')).to eq('1,1.2,1.2.3')
          expect(expander.expand('${tag_suffix[0]},${tag_suffix[1]},${tag_suffix[2]}')).to eq('3,2.3,1.2.3')
        end

        it 'does not expand an index which the tag does not have' do
          # tag_prefix and tag_suffix have no negative index, so they are kept
          # as they are. This checks that the record does not fill them.
          expander = builder.build(forged_placeholder)

          expect(expander.expand('${tag_prefix[-1]}')).to eq('${tag_prefix[-1]}')
          expect(expander.expand('${tag_suffix[-1]}')).to eq('${tag_suffix[-1]}')

          # the tag has 3 parts, so the 4th value of the record is out of it.
          longer = forged_placeholder.merge('tag_parts' => %w[forged forged forged forged])
          expander = builder.build(longer)

          expect(expander.expand('${tag_parts[3]}')).to eq('${tag_parts[3]}')
          expect(expander.expand('${tag_parts[-4]}')).to eq('${tag_parts[-4]}')
        end
      end

      # a record may also have a key named "tag_parts[0]", which makes the
      # same placeholder as the tag
      context 'with a value whose key is a tag placeholder' do
        it 'expands the placeholders with the tag' do
          spelled = {
            'tag' => '1.2.3',
            'tag_parts[0]' => 'forged',
            'tag_prefix[0]' => 'forged',
            'tag_suffix[0]' => 'forged',
          }
          expander = builder.build(spelled)

          expect(expander.expand('${tag_parts[0]}')).to eq('1')
          expect(expander.expand('${tag_prefix[0]}')).to eq('1')
          expect(expander.expand('${tag_suffix[0]}')).to eq('3')
        end

        it 'does not expand an index which the tag does not have' do
          spelled = {
            'tag' => '1',
            'tag_parts[1]' => 'forged',
            'tag_parts[-2]' => 'forged',
            'tag_prefix[-1]' => 'forged',
            'tag_suffix[-1]' => 'forged',
          }
          expander = builder.build(spelled)

          expect(expander.expand('${tag_parts[1]}')).to eq('${tag_parts[1]}')
          expect(expander.expand('${tag_parts[-2]}')).to eq('${tag_parts[-2]}')
          expect(expander.expand('${tag_prefix[-1]}')).to eq('${tag_prefix[-1]}')
          expect(expander.expand('${tag_suffix[-1]}')).to eq('${tag_suffix[-1]}')
        end

        it 'keeps the tag itself' do
          spelled = {
            'tag' => '1.2.3',
            'tag_parts' => 'forged',
            'tag_prefix' => 'forged',
            'tag_suffix' => 'forged',
          }
          expander = builder.build(spelled)

          expect(expander.expand('${tag}')).to eq('1.2.3')
          # these are not built from the tag, so they are kept as they are
          expect(expander.expand('${tag_parts}')).to eq('${tag_parts}')
          expect(expander.expand('${tag_prefix}')).to eq('${tag_prefix}')
          expect(expander.expand('${tag_suffix}')).to eq('${tag_suffix}')
        end
      end

      context 'when not found placeholder' do
        it 'prints wanring log and as it is' do
          expect(log).to receive(:warn).with('unknown placeholder `${tag_prefix[100]}` found').once

          expander = builder.build(static_placeholder)
          expect(expander.expand('${tag_prefix[100]}')).to eq('${tag_prefix[100]}')
        end
      end
    end

    context 'with dynamic placeholder' do
      let(:static_placeholder) do
        {
          'hostname' => 'host_value',
          'ary_value' => ['1', '2', '3'],
          'hash_value' => { 'key1' => 'val1' },
        }
      end

      let(:dynamic_placeholder) do
        { 'tag' => '1.2.3'}
      end

      it 'expands values' do
        expander = builder.build(static_placeholder)
        expect(expander.expand('${hostname}', dynamic_placeholders: dynamic_placeholder)).to eq('host_value')
        expect(expander.expand('${ary_value[0]}.${ary_value[1]}.${ary_value[2]}', dynamic_placeholders: dynamic_placeholder)).to eq('1.2.3')
        expect(expander.expand('${ary_value[-3]}.${ary_value[-2]}.${ary_value[-1]}', dynamic_placeholders: dynamic_placeholder)).to eq('1.2.3')
        expect(expander.expand('${hash_value["key1"]}', dynamic_placeholders: dynamic_placeholder)).to eq('val1')

        expect(expander.expand('${tag}', dynamic_placeholders: dynamic_placeholder)).to eq('1.2.3')
        expect(expander.expand('${tag_parts[0]}.${tag_parts[1]}.${tag_parts[2]}', dynamic_placeholders: dynamic_placeholder)).to eq('1.2.3')
        expect(expander.expand('${tag_parts[-3]}.${tag_parts[-2]}.${tag_parts[-1]}', dynamic_placeholders: dynamic_placeholder)).to eq('1.2.3')
        expect(expander.expand('${tag_prefix[0]}.${tag_prefix[1]}.${tag_prefix[2]}', dynamic_placeholders: dynamic_placeholder)).to eq('1.1.2.1.2.3')
        expect(expander.expand('${tag_suffix[0]}.${tag_suffix[1]}.${tag_suffix[2]}', dynamic_placeholders: dynamic_placeholder)).to eq('3.2.3.1.2.3')
      end

      it 'expands the placeholders with the dynamic tag' do
        forged = static_placeholder.merge('tag_parts' => %w[forged forged forged])
        expander = builder.build(forged)

        expect(expander.expand('${tag_parts[0]}.${tag_parts[1]}.${tag_parts[2]}',
                               dynamic_placeholders: dynamic_placeholder)).to eq('1.2.3')
      end

      it 'does not create expander twice if given the same placeholder' do
        builder # cached before mock

        expect(Fluent::Plugin::Prometheus::ExpandBuilder).to receive(:build).with(anything, log: anything).once.and_call_original
        expander = builder.build(static_placeholder)
        placeholder = { 'tag' => 'val.test' }
        expander.expand('${hostname}', dynamic_placeholders: placeholder)
        expander.expand('${hostname}', dynamic_placeholders: placeholder)
      end

      it 'creates new expander for each placeholder' do
        builder # cached before mock

        expect(Fluent::Plugin::Prometheus::ExpandBuilder).to receive(:build).with(anything, log: anything).twice.and_call_original
        expander = builder.build(static_placeholder)
        expander.expand('${hostname}', dynamic_placeholders: { 'tag' => 'val.test' })
        expander.expand('${hostname}', dynamic_placeholders: { 'tag' => 'val.test2' })
      end
    end
  end
end
