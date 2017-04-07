require 'spec_helper'

module Bosh::Director
  describe Api::SnapshotManager do
    let(:cloud) { Config.cloud }
    let(:cloud_factory) { instance_double(Bosh::Director::CloudFactory) }
    let(:username) { 'username-1' }
    let(:time) { Time.now.utc.to_s }

    let(:deployment) { Models::Deployment.make(name: 'deployment') }
    let(:job_queue) { instance_double('Bosh::Director::JobQueue') }
    let(:options) { { foo: 'bar' } }

    before do
      allow(Config).to receive_messages(cloud: cloud)

      # instance 1: one disk with two snapshots
      @vm = Models::Vm.make(cid: 'vm-cid0', agent_id: 'agent0')
      @instance = Models::Instance.make(deployment: deployment, job: 'job', index: 0, uuid: '12abdc456', availability_zone: 'az1')
      @instance.add_vm(@vm)
      @instance.active_vm = @vm

      @disk = Models::PersistentDisk.make(disk_cid: 'disk0', instance: @instance, active: true)
      Models::Snapshot.make(persistent_disk: @disk, snapshot_cid: 'snap0a', created_at: time, clean: true)
      Models::Snapshot.make(persistent_disk: @disk, snapshot_cid: 'snap0b', created_at: time)

      # instance 2: 1 disk
      vm = Models::Vm.make(cid: 'vm-cid1', agent_id: 'agent1')
      instance = Models::Instance.make(deployment: deployment, job: 'job', index: 1, uuid: '12xyz456', availability_zone: 'az2')
      instance.add_vm(vm)
      instance.active_vm = vm

      disk = Models::PersistentDisk.make(disk_cid: 'disk1', instance: instance, active: true)
      Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1a', created_at: time)

      # instance 3: no disks
      @vm2 = Models::Vm.make(cid: 'vm-cid2', agent_id: 'agent2')
      @instance2 = Models::Instance.make(deployment: deployment, job: 'job2', index: 0, uuid: '12def456', availability_zone: 'az3')
      @instance2.add_vm(@vm2)
      @instance2.active_vm = @vm2

      # snapshot from another deployment
      Models::Snapshot.make

      allow(JobQueue).to receive(:new).and_return(job_queue)
      allow(Bosh::Director::CloudFactory).to receive(:new).and_return(cloud_factory)
    end

    let(:task) { instance_double('Bosh::Director::Models::Task', id: 'task_id') }

    describe '#create_deployment_snapshot_task' do
      it 'enqueues a SnapshotDeployment job' do
        expect(job_queue).to receive(:enqueue).with(
          username, Jobs::SnapshotDeployment, 'snapshot deployment', [deployment.name, options], deployment
        ).and_return(task)

        expect(subject.create_deployment_snapshot_task(username, deployment, options)).to eq(task)
      end
    end

    describe '#create_snapshot_task' do
      let(:instance) { instance_double('Bosh::Director::Models::Instance', id: 0) }

      it 'should enqueue a CreateSnapshot job' do
        expect(job_queue).to receive(:enqueue).with(
          username, Jobs::CreateSnapshot, 'create snapshot', [instance.id, options]
        ).and_return(task)

        expect(subject.create_snapshot_task(username, instance, options)).to eq(task)
      end
    end

    describe '#delete_deployment_snapshots_task' do
      it 'enqueues a DeleteDeploymentSnapshots job' do
        expect(job_queue).to receive(:enqueue).with(
          username, Jobs::DeleteDeploymentSnapshots, 'delete deployment snapshots', [deployment.name], deployment
        ).and_return(task)

        expect(subject.delete_deployment_snapshots_task(username, deployment)).to eq(task)
      end
    end

    describe '#delete_snapshots_task' do
      let(:snapshot_cids) { %w[snap0 snap1] }

      it 'enqueues a DeleteSnapshots job' do
        expect(job_queue).to receive(:enqueue).with(
          username, Jobs::DeleteSnapshots, 'delete snapshot', [snapshot_cids]).and_return(task)

        expect(subject.delete_snapshots_task(username, snapshot_cids)).to eq(task)
      end
    end

    describe '#find_by_cid' do
      it 'should return the snapshot with the given id' do
        expect(subject.find_by_cid(deployment, 'snap0a').snapshot_cid).to eq 'snap0a'
      end
    end

    describe '#snapshots' do
      it 'should list all snapshots for a given deployment' do
        response = [
          { 'job' => 'job', 'index' => 0, 'uuid' => '12abdc456','snapshot_cid' => 'snap0a', 'created_at' => time, 'clean' => true },
          { 'job' => 'job', 'index' => 0, 'uuid' => '12abdc456','snapshot_cid' => 'snap0b', 'created_at' => time, 'clean' => false },
          { 'job' => 'job', 'index' => 1, 'uuid' => '12xyz456','snapshot_cid' => 'snap1a', 'created_at' => time, 'clean' => false },
        ]
        expect(subject.snapshots(deployment)).to match_array response
      end

      describe 'when index is supplied' do
        it 'should list all snapshots for a given instance' do
          response = [
            {'job' => 'job', 'index' => 0, 'uuid' => '12abdc456', 'snapshot_cid' => 'snap0a', 'created_at' => time, 'clean' => true},
            {'job' => 'job', 'index' => 0, 'uuid' => '12abdc456', 'snapshot_cid' => 'snap0b', 'created_at' => time, 'clean' => false},
          ]
          expect(subject.snapshots(deployment, 'job', 0)).to eq response
        end
      end

      describe 'when id is supplied' do
        it 'should list all snapshots for a given instance' do
          response = [
            {'job' => 'job', 'index' => 0, 'uuid' => '12abdc456', 'snapshot_cid' => 'snap0a', 'created_at' => time, 'clean' => true},
            {'job' => 'job', 'index' => 0, 'uuid' => '12abdc456', 'snapshot_cid' => 'snap0b', 'created_at' => time, 'clean' => false},
          ]
          expect(subject.snapshots(deployment, 'job', @instance.uuid)).to eq response
        end
      end
    end

    describe 'class methods' do
      let(:config) { YAML.load_file(asset('test-director-config.yml')) }

      before do
        Config.configure(config)
        allow(Config).to receive(:enable_snapshots).and_return(true)
      end

      describe '#delete_snapshots' do
        it 'deletes the snapshots' do
          expect(Config.cloud).to receive(:delete_snapshot).with('snap0a')
          expect(Config.cloud).to receive(:delete_snapshot).with('snap0b')
          expect(cloud_factory).to receive(:for_availability_zone).with(@instance.availability_zone).twice.and_return(cloud)

          expect {
            described_class.delete_snapshots(@disk.snapshots)
          }.to change { Models::Snapshot.count }.by -2
        end

        context 'when keep_snapshots_in_cloud option is passed' do
          it 'keeps snapshots in the IaaS' do
            expect(Config.cloud).to_not receive(:delete_snapshot)

            expect {
              described_class.delete_snapshots(@disk.snapshots, keep_snapshots_in_the_cloud: true)
            }.to change { Models::Snapshot.count }.by -2
          end
        end
      end

      describe '#take_snapshot' do
        let(:metadata) {
          {
            agent_id: 'agent0',
            director_name: 'Test Director',
            director_uuid: Config.uuid,
            deployment: 'deployment',
            job: 'job',
            index: 0
          }
        }

        context 'when there is no persistent disk' do
          it 'does not take a snapshot' do
            expect(Config.cloud).not_to receive(:snapshot_disk)
            expect(cloud_factory).to receive(:for_availability_zone!).with(@instance2.availability_zone).and_return(cloud)

            expect {
              described_class.take_snapshot(@instance2, {})
            }.to_not change { Models::Snapshot.count }
          end
        end

        it 'takes the snapshot' do
          expect(Config.cloud).to receive(:snapshot_disk).with('disk0', metadata).and_return('snap0c')
          expect(cloud_factory).to receive(:for_availability_zone!).with(@instance.availability_zone).and_return(cloud)

          expect {
            expect(described_class.take_snapshot(@instance, {})).to eq %w[snap0c]
          }.to change { Models::Snapshot.count }.by 1
        end

        context 'with the clean option' do
          it 'it sets the clean column to true in the db' do
            expect(Config.cloud).to receive(:snapshot_disk).with('disk0', metadata).and_return('snap0c')
            expect(cloud_factory).to receive(:for_availability_zone!).with(@instance.availability_zone).and_return(cloud)
            expect(described_class.take_snapshot(@instance, { :clean => true })).to eq %w[snap0c]

            snapshot = Models::Snapshot.find(snapshot_cid: 'snap0c')
            expect(snapshot.clean).to be(true)
          end
        end

        context 'when snapshotting is disabled' do
          it 'does nothing' do
            allow(Config).to receive(:enable_snapshots).and_return(false)

            expect(described_class.take_snapshot(@instance)).to be_empty
          end
        end

        context 'with a CPI that does not support snapshots' do
          it 'does nothing' do
            allow(Config.cloud).to receive(:snapshot_disk).and_raise(Bosh::Clouds::NotImplemented)
            expect(cloud_factory).to receive(:for_availability_zone!).with(@instance.availability_zone).and_return(cloud)

            expect(described_class.take_snapshot(@instance)).to be_empty
          end
        end
      end
    end
  end
end
