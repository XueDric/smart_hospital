/*
 * Copyright (C) 2024 Yesokim
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
protected package mariadb.protocol

protected class QuitCommand <: Command {

    protected init() {
        super(Quit)
    }

}

protected class InitDbCommand <: Command {

    private let database: String

    protected init(database: String) {
        super(InitDB)
        this.database = database
    }

    protected override func pack(): Unit {
        super.pack()
        database |> buffer.writeString
    }
}

protected class StatisticsCommand <: Command {

    protected init() {
        super(Statistics)
    }

}

protected class DebugCommand <: Command {
    protected init() {
        super(Debug)
    }
}

protected class PingCommand <: Command {
    protected init() {
        super(Ping)
    }
}

protected class ResetConnectionCommand <: Command {
    protected init() {
        super(ResetConnection)
    }
}

protected class SetOptionCommand <: Command {

    private let operation: StatementOption

    protected init(option: StatementOption) {
        super(SetOption)
        operation = option
    }

    protected override func pack(): Unit {
        super.pack()
        operation.value() |> buffer.writeInt2
    }

}