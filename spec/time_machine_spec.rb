require 'spec_helper'
require 'support/helpers'

describe ChronoModel::TimeMachine do
  include ChronoTest::Helpers::TimeMachine

  setup_schema!
  define_models!

  describe '.chrono_models' do
    subject { ChronoModel::TimeMachine.chrono_models }

    it { should == {'foos' => Foo::History, 'defoos' => Defoo::History, 'bars' => Bar::History} }
  end


  # Set up two associated records, with intertwined updates
  #
  let!(:foo) {
    foo = ts_eval { Foo.create! :name => 'foo', :fooity => 1 }
    ts_eval(foo) { update_attributes! :name => 'foo bar' }
  }

  let!(:bar) {
    bar = ts_eval { Bar.create! :name => 'bar', :foo => foo }
    ts_eval(bar) { update_attributes! :name => 'foo bar' }

    ts_eval(foo) { update_attributes! :name => 'new foo' }

    ts_eval(bar) { update_attributes! :name => 'bar bar' }
    ts_eval(bar) { update_attributes! :name => 'new bar' }
  }

  # Specs start here
  #
  describe '#as_of' do
    describe 'accepts a Time instance' do
      it { foo.as_of(Time.now).name.should == 'new foo' }
      it { bar.as_of(Time.now).name.should == 'new bar' }
    end

    describe 'ignores time zones' do
      it { foo.as_of(Time.now.in_time_zone('America/Havana')).name.should == 'new foo' }
      it { bar.as_of(Time.now.in_time_zone('America/Havana')).name.should == 'new bar' }
    end

    describe 'returns records as they were before' do
      it { foo.as_of(foo.ts[0]).name.should == 'foo' }
      it { foo.as_of(foo.ts[1]).name.should == 'foo bar' }
      it { foo.as_of(foo.ts[2]).name.should == 'new foo' }

      it { bar.as_of(bar.ts[0]).name.should == 'bar' }
      it { bar.as_of(bar.ts[1]).name.should == 'foo bar' }
      it { bar.as_of(bar.ts[2]).name.should == 'bar bar' }
      it { bar.as_of(bar.ts[3]).name.should == 'new bar' }
    end

    describe 'takes care of associated records' do
      it { foo.as_of(foo.ts[0]).bars.should == [] }
      it { foo.as_of(foo.ts[1]).bars.should == [] }
      it { foo.as_of(foo.ts[2]).bars.should == [bar] }

      it { foo.as_of(foo.ts[2]).bars.first.name.should == 'foo bar' }


      it { foo.as_of(bar.ts[0]).bars.should == [bar] }
      it { foo.as_of(bar.ts[1]).bars.should == [bar] }
      it { foo.as_of(bar.ts[2]).bars.should == [bar] }
      it { foo.as_of(bar.ts[3]).bars.should == [bar] }

      it { foo.as_of(bar.ts[0]).bars.first.name.should == 'bar' }
      it { foo.as_of(bar.ts[1]).bars.first.name.should == 'foo bar' }
      it { foo.as_of(bar.ts[2]).bars.first.name.should == 'bar bar' }
      it { foo.as_of(bar.ts[3]).bars.first.name.should == 'new bar' }


      it { bar.as_of(bar.ts[0]).foo.should == foo }
      it { bar.as_of(bar.ts[1]).foo.should == foo }
      it { bar.as_of(bar.ts[2]).foo.should == foo }
      it { bar.as_of(bar.ts[3]).foo.should == foo }

      it { bar.as_of(bar.ts[0]).foo.name.should == 'foo bar' }
      it { bar.as_of(bar.ts[1]).foo.name.should == 'foo bar' }
      it { bar.as_of(bar.ts[2]).foo.name.should == 'new foo' }
      it { bar.as_of(bar.ts[3]).foo.name.should == 'new foo' }
    end

    it 'raises RecordNotFound when no history records are found' do
      expect { foo.as_of(1.minute.ago) }.to raise_error
    end

    describe 'it honors default_scopes' do
      let!(:active) {
        active = ts_eval { Defoo.create! :name => 'active 1', :active => true }
        ts_eval(active) { update_attributes! :name => 'active 2' }
      }

      let!(:hidden) {
        hidden = ts_eval { Defoo.create! :name => 'hidden 1', :active => false }
        ts_eval(hidden) { update_attributes! :name => 'hidden 2' }
      }

      it { Defoo.as_of(active.ts[0]).map(&:name).should == ['active 1'] }
      it { Defoo.as_of(active.ts[1]).map(&:name).should == ['active 2'] }
      it { Defoo.as_of(hidden.ts[0]).map(&:name).should == ['active 2'] }
      it { Defoo.as_of(hidden.ts[1]).map(&:name).should == ['active 2'] }

      it { Defoo.unscoped.as_of(active.ts[0]).map(&:name).should == ['active 1'] }
      it { Defoo.unscoped.as_of(active.ts[1]).map(&:name).should == ['active 2'] }
      it { Defoo.unscoped.as_of(hidden.ts[0]).map(&:name).should == ['active 2', 'hidden 1'] }
      it { Defoo.unscoped.as_of(hidden.ts[1]).map(&:name).should == ['active 2', 'hidden 2'] }
    end
  end

  describe '#history' do
    describe 'returns historical instances' do
      it { foo.history.should have(3).entries }
      it { foo.history.map(&:name).should == ['foo', 'foo bar', 'new foo'] }

      it { bar.history.should have(4).entries }
      it { bar.history.map(&:name).should == ['bar', 'foo bar', 'bar bar', 'new bar'] }
    end

    describe 'returns read only records' do
      it { foo.history.all?(&:readonly?).should be_true }
      it { bar.history.all?(&:readonly?).should be_true }
    end

    describe 'takes care of associated records' do
      subject { foo.history.map {|f| f.bars.first.try(:name)} }
      it { should == [nil, 'foo bar', 'new bar'] }
    end

    describe 'returns read only associated records' do
      it { foo.history[2].bars.all?(&:readonly?).should be_true }
      it { bar.history.all? {|b| b.foo.readonly?}.should be_true }
    end
  end

  describe '#historical?' do
    describe 'on plain records' do
      subject { foo.historical? }
      it { should be_false }
    end

    describe 'on historical records' do
      describe 'from #history' do
        subject { foo.history.first }
        it { should be_true }
      end

      describe 'from #as_of' do
        subject { foo.as_of(Time.now) }
        it { should be_true }
      end
    end
  end

  describe '#destroy' do
    describe 'on historical records' do
      subject { foo.history.first.destroy }
      it { expect { subject }.to raise_error(ActiveRecord::ReadOnlyRecord) }
    end

    describe 'on current records' do
      let!(:rec) {
        rec = ts_eval { Foo.create!(:name => 'alive foo', :fooity => 42) }
        ts_eval(rec) { update_attributes!(:name => 'dying foo') }
      }

      subject { rec.destroy }

      it { expect { subject }.to_not raise_error }
      it { expect { rec.reload }.to raise_error(ActiveRecord::RecordNotFound) }

      describe 'does not delete its history' do
        context do
          subject { rec.as_of(rec.ts.first) }
          its(:name) { should == 'alive foo' }
        end

        context do
          subject { rec.as_of(rec.ts.last) }
          its(:name) { should == 'dying foo' }
        end

        context do
          subject { Foo.as_of(rec.ts.first).where(:fooity => 42).first }
          its(:name) { should == 'alive foo' }
        end

        context do
          subject { Foo.history.where(:fooity => 42).map(&:name) }
          it { should == ['alive foo', 'dying foo'] }
        end
      end
    end
  end

  describe '#history_timestamps' do
    timestamps_from = lambda {|*records|
      records.map(&:history).flatten!.inject([]) {|ret, rec|
        ret.concat [rec.valid_from, rec.valid_to]
      }.sort.uniq[0..-2]
    }

    describe 'on records having an :has_many relationship' do
      subject { foo.history_timestamps }

      describe 'returns timestamps of the record and its associations' do
        its(:size) { should == foo.ts.size + bar.ts.size }
        it { should == timestamps_from.call(foo, bar) }
      end
    end

    describe 'on records having a :belongs_to relationship' do
      subject { bar.history_timestamps }

      describe 'returns timestamps of the record and its associations' do
        its(:size) { should == foo.ts.size + bar.ts.size }
        it { should == timestamps_from.call(foo, bar) }
      end
    end
  end

  context do
    let!(:history) { foo.history.first }
    let!(:current) { foo }

    spec = lambda {|attr|
      return lambda {|*|
        describe 'on history records' do
          subject { history.public_send(attr) }

          it { should be_present }
          it { should be_a(Time) }
          it { should be_utc }
        end

        describe 'on current records' do
          subject { current.public_send(attr) }
          it { expect { subject }.to raise_error(NoMethodError) }
        end
      }
    }

    %w( valid_from valid_to recorded_at as_of_time ).each do |attr|
      describe ['#', attr].join, &spec.call(attr)
    end
  end

  # Class methods
  context do
    let!(:foos) { Array.new(2) {|i| ts_eval { Foo.create! :name => "foo #{i}" } } }
    let!(:bars) { Array.new(2) {|i| ts_eval { Bar.create! :name => "bar #{i}", :foo => foos[i] } } }

    after(:all) { foos.each(&:destroy); bars.each(&:destroy) }

    describe '.as_of' do
      it { Foo.as_of(1.month.ago).should == [] }

      it { Foo.as_of(foos[0].ts[0]).should == [foo, foos[0]] }
      it { Foo.as_of(foos[1].ts[0]).should == [foo, foos[0], foos[1]] }
      it { Foo.as_of(Time.now     ).should == [foo, foos[0], foos[1]] }

      it { Bar.as_of(foos[1].ts[0]).should == [bar] }

      it { Bar.as_of(bars[0].ts[0]).should == [bar, bars[0]] }
      it { Bar.as_of(bars[1].ts[0]).should == [bar, bars[0], bars[1]] }
      it { Bar.as_of(Time.now     ).should == [bar, bars[0], bars[1]] }

      # Associations
      context do
        subject { foos[0] }

        it { Foo.as_of(foos[0].ts[0]).find(subject).bars.should == [] }
        it { Foo.as_of(foos[1].ts[0]).find(subject).bars.should == [] }
        it { Foo.as_of(bars[0].ts[0]).find(subject).bars.should == [bars[0]] }
        it { Foo.as_of(bars[1].ts[0]).find(subject).bars.should == [bars[0]] }
        it { Foo.as_of(Time.now     ).find(subject).bars.should == [bars[0]] }
      end

      context do
        subject { foos[1] }

        it { expect { Foo.as_of(foos[0].ts[0]).find(subject) }.to raise_error(ActiveRecord::RecordNotFound) }
        it { expect { Foo.as_of(foos[1].ts[0]).find(subject) }.to_not raise_error }

        it { Foo.as_of(bars[0].ts[0]).find(subject).bars.should == [] }
        it { Foo.as_of(bars[1].ts[0]).find(subject).bars.should == [bars[1]] }
        it { Foo.as_of(Time.now     ).find(subject).bars.should == [bars[1]] }
      end
    end

    describe '.history' do
      let(:foo_history) {
        ['foo', 'foo bar', 'new foo', 'alive foo', 'dying foo', 'foo 0', 'foo 1']
      }

      let(:bar_history) {
        ['bar', 'foo bar', 'bar bar', 'new bar', 'bar 0', 'bar 1']
      }

      it { Foo.history.all.map(&:name).should == foo_history }
      it { Bar.history.all.map(&:name).should == bar_history }
    end
  end

  # Transactions
  context 'Within transactions' do
    context 'multiple updates to an existing record' do
      let!(:r1) do
        Foo.create!(:name => 'xact test').tap do |record|
          Foo.transaction do
            record.update_attribute 'name', 'lost into oblivion'
            record.update_attribute 'name', 'does work'
          end
        end
      end

      it "generate only a single history record" do
        r1.history.should have(2).entries

        r1.history.first.name.should == 'xact test'
        r1.history.last.name.should  == 'does work'
      end
    end

    context 'insertion and subsequent update' do
      let!(:r2) do
        Foo.transaction do
          Foo.create!(:name => 'lost into oblivion').tap do |record|
            record.update_attribute 'name', 'I am Bar'
            record.update_attribute 'name', 'I am Foo'
          end
        end
      end

      it 'generates a single history record' do
        r2.history.should have(1).entry

        r2.history.first.name.should == 'I am Foo'
      end
    end

    context 'insertion and subsequent deletion' do
      let!(:r3) do
        Foo.transaction do
          Foo.create!(:name => 'it never happened').destroy
        end
      end

      it 'does not generate any history' do
        Foo.history.where(:id => r3.id).should be_empty
      end
    end
  end

end
